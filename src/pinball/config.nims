# Build settings for the playable program, on top of the repository's
# config.nims. Only the browser build needs any: `-d:emscripten` compiles to
# WebAssembly with emcc and writes the bundle into web/game/. Use
# tools/build_web.sh, which puts emcc on the path first.

import std/os

when defined(emscripten):
  let
    repository = currentSourcePath().parentDir.parentDir.parentDir
    outputFolder = repository / "web" / "game"
  mkDir(outputFolder)

  switch("nimcache", repository / "build" / "nimcache" / "web")
  switch("out", outputFolder / "pinball.js")
  switch("threads", "off")
  --os:linux
  --cpu:wasm32
  --cc:clang
  --clang.exe:emcc
  --clang.linkerexe:emcc
  --clang.cpp.exe:emcc
  --clang.cpp.linkerexe:emcc
  --mm:arc
  --exceptions:goto
  --define:noSignalHandler

  # The sounds travel in pinball.data and appear to the game as /assets/sounds.
  switch("passL", "--preload-file " & quoteShell(repository / "assets" / "sounds") &
    "@/assets/sounds")
  # Nim's -O3 only reaches the compile step. emcc needs it again to link, or
  # the WebAssembly and the Asyncify rewrite are left unoptimised.
  when not defined(debug):
    switch("passL", "-O3")
  # ASYNCIFY lets the main loop sleep until the next frame without returning.
  # FETCH is there because windy links against it. The two lists keep what
  # view/bridge.nim uses to hand a string from the page to the game.
  switch("passL", "-sASYNCIFY -sFETCH -sUSE_WEBGL2=1 -sMAX_WEBGL_VERSION=2 -sMIN_WEBGL_VERSION=2 " &
    "-sFULL_ES3=1 -sGL_ENABLE_GET_PROC_ADDRESS=1 -sALLOW_MEMORY_GROWTH " &
    "-sEXPORTED_FUNCTIONS=_main,_malloc,_free " &
    "-sDEFAULT_LIBRARY_FUNCS_TO_INCLUDE='$stringToNewUTF8'")
