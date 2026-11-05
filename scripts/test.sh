#!/bin/sh
set -eu
PACKAGE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DSH_APPLICATION=${DSH_APP_PATH:-'/Applications/DeepSeek Harness.app'}
DSH_TEST_RESOURCES="$DSH_APPLICATION/Contents/Resources" ELECTRON_RUN_AS_NODE=1 \
  "$DSH_APPLICATION/Contents/MacOS/DeepSeek Harness" --expose-internals --test \
  "$PACKAGE_DIR/test/engine.test.mjs" "$PACKAGE_DIR/test/install.test.cjs" "$PACKAGE_DIR/test/catalog.test.mjs" "$PACKAGE_DIR/test/markdown.test.cjs" "$PACKAGE_DIR/test/opencode.test.mjs"
