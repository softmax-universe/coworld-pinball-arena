#!/bin/sh
# Runs every Nim test file, then the JavaScript tests. Run from anywhere.
# -d:fixedChecks turns a fixed-point overflow into a failed assertion.
cd "$(dirname "$0")/.." || exit 1
failed=0
for test in tests/test_*.nim; do
  name=$(basename "$test" .nim)
  echo "== $name"
  nim r --hints:off --warnings:off -d:fixedChecks \
    --nimcache:"build/nimcache/$name" "$test" || failed=1
done
echo "== javascript"
npm test --silent || failed=1
exit $failed
