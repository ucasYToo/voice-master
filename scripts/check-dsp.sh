#!/bin/bash
set -euo pipefail

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/voice-master-dsp.XXXXXX")"
trap 'rm -rf -- "$build_dir"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

xcrun clang \
  -std=c11 -Wall -Wextra -Werror \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -I"$project_root/Sources/RealtimeDSP/include" \
  "$project_root/Sources/RealtimeDSP/RealtimeDSP.c" \
  "$project_root/Tests/RealtimeDSPHarness/main.c" \
  -framework CoreAudio \
  -o "$build_dir/check-dsp"

"$build_dir/check-dsp"
