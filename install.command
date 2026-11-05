#!/bin/sh
set -eu
PACKAGE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DSH_APPLICATION=${DSH_APP_PATH:-'/Applications/DeepSeek Harness.app'}
if [ ! -x "$DSH_APPLICATION/Contents/MacOS/DeepSeek Harness" ]; then
  printf '%s\n' '找不到 DeepSeek Harness，请通过 DSH_APP_PATH 指定应用路径。' >&2
  exit 1
fi
ELECTRON_RUN_AS_NODE=1 exec "$DSH_APPLICATION/Contents/MacOS/DeepSeek Harness" --expose-internals \
  "$PACKAGE_DIR/scripts/install.cjs" --resources "$DSH_APPLICATION/Contents/Resources" "$@"
