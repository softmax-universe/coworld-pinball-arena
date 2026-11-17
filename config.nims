import std/[os, strutils]

switch("hint", "[CC]:off")

--path:"src"

# Dependencies are plain checkouts pinned by nimby.lock. They live in `deps/`
# inside this repository (git-ignored); see the README for the sync command.
# PINBALL_DEPS points somewhere else, and <NAME>_PATH overrides one package.
let
  projectRoot = currentSourcePath().parentDir
  dependencyRoot = getEnv("PINBALL_DEPS", projectRoot / "deps")
for line in readFile(projectRoot / "nimby.lock").splitLines():
  let fields = line.splitWhitespace()
  if fields.len == 0:
    continue
  let
    name = fields[0]
    directory = dependencyRoot / name
    source =
      if dirExists(directory / "src"):
        directory / "src"
      else:
        directory
  switch("path", getEnv(name.toUpperAscii() & "_PATH", source))

--define:nimTypeNames
--define:flatty64

# Compile BASIC programs to machine code on native targets. The browser build
# always uses the interpreter, and both give the same results.
--define:bassyNative

when not defined(debug):
  --define:release
  --define:noAutoGLerrorCheck
