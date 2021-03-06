#!/bin/bash

# Fast fail the script on failures.
set -e

# Skipping format check for now – until 1.12 is stable
# $(dirname -- "$0")/ensure_dartfmt.sh

# Run the tests.
dart --checked test/test_all.dart

# Install dart_coveralls; gather and send coverage data.
if [ "$COVERALLS_TOKEN" ] && [ "$TRAVIS_DART_VERSION" = "stable" ]; then
  pub global activate dart_coveralls
  pub global run dart_coveralls report \
    --token $COVERALLS_TOKEN \
    --retry 2 \
    --exclude-test-files \
    test/test_all.dart
fi
