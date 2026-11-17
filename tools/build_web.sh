#!/usr/bin/env bash
# Build the game for the browser: web/game/pinball.js, pinball.wasm and
# pinball.data (the sounds). Also copies a bare test page to
# web/game/test.html, which runs the game without the real page around it.
#
#   tools/build_web.sh            release build
#   tools/build_web.sh -d:debug   any further arguments go to nim
#
# Needs nim and Emscripten. If emcc is not on the path, the script looks for
# an emsdk in $EMSDK or ~/coding/tools/emsdk.
set -euo pipefail

repository="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v emcc >/dev/null 2>&1; then
  emsdk_env="${EMSDK:-$HOME/coding/tools/emsdk}/emsdk_env.sh"
  if [[ ! -f "$emsdk_env" ]]; then
    echo "emcc is not on the path and there is no emsdk at $emsdk_env." >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  source "$emsdk_env" >/dev/null 2>&1
fi

cd "$repository"
nim c -d:emscripten --hints:off "$@" src/pinball/pinball.nim
cp tools/web_test.html web/game/test.html

echo "Built:"
ls -l web/game/pinball.js web/game/pinball.wasm web/game/pinball.data
