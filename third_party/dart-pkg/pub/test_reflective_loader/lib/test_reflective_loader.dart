// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library test_reflective_loader;

import 'dart:async';
@MirrorsUsed(metaTargets: 'ReflectiveTest')
import 'dart:mirrors';

import 'package:test/test.dart' as test_package;

/**
 * A marker annotation used to annotate overridden test methods (so we cannot
 * rename them to `fail_`) which are expected to fail at `assert` in the
 * checked mode.
 */
const _AssertFailingTest assertFailingTest = const _AssertFailingTest();

/**
 * A marker annotation used to annotate overridden test methods (so we cannot
 * rename them to `fail_`) which are expected to fail.
 */
const _FailingTest failingTest = const _FailingTest();

/**
 * A marker annotation used to instruct dart2js to keep reflection information
 * for the annotated classes.
 */
const ReflectiveTest reflectiveTest = const ReflectiveTest();

/**
 * A marker annotation used to annotate "solo" groups and tests.
 */
const _SoloTest soloTest = const _SoloTest();

final List<_Group> _currentGroups = <_Group>[];
int _currentSuiteLevel = 0;
String _currentSuiteName = null;

/**
 * Is `true` the application is running in the checked mode.
 */
final bool _isCheckedMode = () {
  try {
    assert(false);
    return false;
  } catch (_) {
    return true;
  }
}();

/**
 * Run the [define] function parameter that calls [defineReflectiveTests] to
 * add normal and "solo" tests, and also calls [defineReflectiveSuite] to
 * create embedded suites.  If the current suite is the top-level one, perform
 * check for "solo" groups and tests, and run all or only "solo" items.
 */
void defineReflectiveSuite(void define(), {String name}) {
  String groupName = _currentSuiteName;
  _currentSuiteLevel++;
  try {
    _currentSuiteName = _combineNames(_currentSuiteName, name);
    define();
  } finally {
    _currentSuiteName = groupName;
    _currentSuiteLevel--;
  }
  _addTestsIfTopLevelSuite();
}

/**
 * Runs test methods existing in the given [type].
 *
 * If there is a "solo" test method in the top-level suite, only "solo" methods
 * are run.
 *
 * If there is a "solo" test type, only its test methods are run.
 *
 * Otherwise all tests methods of all test types are run.
 *
 * Each method is run with a new instance of [type].
 * So, [type] should have a default constructor.
 *
 * If [type] declares method `setUp`, it methods will be invoked before any test
 * method invocation.
 *
 * If [type] declares method `tearDown`, it will be invoked after any test
 * method invocation. If method returns [Future] to test some asynchronous
 * behavior, then `tearDown` will be invoked in `Future.complete`.
 */
void defineReflectiveTests(Type type) {
  ClassMirror classMirror = reflectClass(type);
  if (!classMirror.metadata.any((InstanceMirror annotation) =>
      annotation.type.reflectedType == ReflectiveTest)) {
    String name = MirrorSystem.getName(classMirror.qualifiedName);
    throw new Exception('Class $name must have annotation "@reflectiveTest" '
        'in order to be run by runReflectiveTests.');
  }

  _Group group;
  {
    bool isSolo = _hasAnnotationInstance(classMirror, soloTest);
    String className = MirrorSystem.getName(classMirror.simpleName);
    group = new _Group(isSolo, _combineNames(_currentSuiteName, className));
    _currentGroups.add(group);
  }

  classMirror.instanceMembers
      .forEach((Symbol symbol, MethodMirror memberMirror) {
    // we need only methods
    if (memberMirror is! MethodMirror || !memberMirror.isRegularMethod) {
      return;
    }
    // prepare information about the method
    String memberName = MirrorSystem.getName(symbol);
    bool isSolo = memberName.startsWith('solo_') ||
        _hasAnnotationInstance(memberMirror, soloTest);
    // test_
    if (memberName.startsWith('test_')) {
      group.addTest(isSolo, memberName, () {
        if (_hasFailingTestAnnotation(memberMirror) ||
            _isCheckedMode && _hasAssertFailingTestAnnotation(memberMirror)) {
          return _runFailingTest(classMirror, symbol);
        } else {
          return _runTest(classMirror, symbol);
        }
      });
      return;
    }
    // solo_test_
    if (memberName.startsWith('solo_test_')) {
      group.addTest(true, memberName, () {
        return _runTest(classMirror, symbol);
      });
    }
    // fail_test_
    if (memberName.startsWith('fail_')) {
      group.addTest(isSolo, memberName, () {
        return _runFailingTest(classMirror, symbol);
      });
    }
    // solo_fail_test_
    if (memberName.startsWith('solo_fail_')) {
      group.addTest(true, memberName, () {
        return _runFailingTest(classMirror, symbol);
      });
    }
  });

  // Support for the case of missing enclosing [defineReflectiveSuite].
  _addTestsIfTopLevelSuite();
}

/**
 * If the current suite is the top-level one, add tests to the `test` package.
 */
void _addTestsIfTopLevelSuite() {
  if (_currentSuiteLevel == 0) {
    void runTests({bool allGroups, bool allTests}) {
      for (_Group group in _currentGroups) {
        if (allGroups || group.isSolo) {
          for (_Test test in group.tests) {
            if (allTests || test.isSolo) {
              test_package.test(test.name, test.function);
            }
          }
        }
      }
    }

    if (_currentGroups.any((g) => g.hasSoloTest)) {
      runTests(allGroups: true, allTests: false);
    } else if (_currentGroups.any((g) => g.isSolo)) {
      runTests(allGroups: false, allTests: true);
    } else {
      runTests(allGroups: true, allTests: true);
    }
    _currentGroups.clear();
  }
}

/**
 * Return the combination of the [base] and [addition] names.
 * If any other two is `null`, then the other one is returned.
 */
String _combineNames(String base, String addition) {
  if (base == null) {
    return addition;
  } else if (addition == null) {
    return base;
  } else {
    return '$base | $addition';
  }
}

bool _hasAnnotationInstance(DeclarationMirror declaration, instance) =>
    declaration.metadata.any((InstanceMirror annotation) =>
        identical(annotation.reflectee, instance));

bool _hasAssertFailingTestAnnotation(MethodMirror method) =>
    _hasAnnotationInstance(method, assertFailingTest);

bool _hasFailingTestAnnotation(MethodMirror method) =>
    _hasAnnotationInstance(method, failingTest);

Future _invokeSymbolIfExists(InstanceMirror instanceMirror, Symbol symbol) {
  var invocationResult = null;
  InstanceMirror closure;
  try {
    closure = instanceMirror.getField(symbol);
  } on NoSuchMethodError {}

  if (closure is ClosureMirror) {
    invocationResult = closure.apply([]).reflectee;
  }
  return new Future.value(invocationResult);
}

/**
 * Run a test that is expected to fail, and confirm that it fails.
 *
 * This properly handles the following cases:
 * - The test fails by throwing an exception
 * - The test returns a future which completes with an error.
 *
 * However, it does not handle the case where the test creates an asynchronous
 * callback using expectAsync(), and that callback generates a failure.
 */
Future _runFailingTest(ClassMirror classMirror, Symbol symbol) {
  return new Future(() => _runTest(classMirror, symbol)).then((_) {
    test_package.fail('Test passed - expected to fail.');
  }, onError: (_) {});
}

_runTest(ClassMirror classMirror, Symbol symbol) {
  InstanceMirror instanceMirror = classMirror.newInstance(new Symbol(''), []);
  return _invokeSymbolIfExists(instanceMirror, #setUp)
      .then((_) => instanceMirror.invoke(symbol, []).reflectee)
      .whenComplete(() => _invokeSymbolIfExists(instanceMirror, #tearDown));
}

typedef _TestFunction();

/**
 * A marker annotation used to instruct dart2js to keep reflection information
 * for the annotated classes.
 */
class ReflectiveTest {
  const ReflectiveTest();
}

/**
 * A marker annotation used to annotate overridden test methods (so we cannot
 * rename them to `fail_`) which are expected to fail at `assert` in the
 * checked mode.
 */
class _AssertFailingTest {
  const _AssertFailingTest();
}

/**
 * A marker annotation used to annotate overridden test methods (so we cannot
 * rename them to `fail_`) which are expected to fail.
 */
class _FailingTest {
  const _FailingTest();
}

/**
 * Information about a type based test group.
 */
class _Group {
  final bool isSolo;
  final String name;
  final List<_Test> tests = <_Test>[];

  _Group(this.isSolo, this.name);

  bool get hasSoloTest => tests.any((test) => test.isSolo);

  void addTest(bool isSolo, String name, _TestFunction function) {
    String fullName = _combineNames(this.name, name);
    tests.add(new _Test(isSolo, fullName, function));
  }
}

/**
 * A marker annotation used to annotate "solo" groups and tests.
 */
class _SoloTest {
  const _SoloTest();
}

/**
 * Information about a test.
 */
class _Test {
  final bool isSolo;
  final String name;
  final _TestFunction function;

  _Test(this.isSolo, this.name, this.function);
}
