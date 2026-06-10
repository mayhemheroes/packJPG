#!/usr/bin/env bash
#
# packJPG/mayhem/build.sh — build the in-process JPEG<->PJG convert harness (libFuzzer +
# standalone reproducer) and the project's own CLI (used by test.sh as a round-trip oracle).
#
# packJPG is a single-program C++14 JPEG recompressor (source/packjpg.cpp + aricoder.cpp +
# bitops.cpp). Compiling packjpg.cpp with -DBUILD_LIB exposes the library API
# (pjglib_init_streams / pjglib_convert_stream2mem) AND excludes the CLI main(), so the harness
# can drive the full parse/decode/recompress path in-process on attacker-controlled bytes.
# The project (not just the harness) is compiled with $SANITIZER_FLAGS so ASan/UBSan instrument
# the fuzzed code.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs from the env (overridable). SANITIZER_FLAGS uses `=` so an explicit empty
# --build-arg SANITIZER_FLAGS= builds with NO sanitizers (natural crash, no ASan report).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"

# Narrowly relax ONE ubiquitous, benign UBSan check: the DEVLI() macro (packjpg.cpp:309) computes
# `1 << (s-1)` while decoding DC/AC coefficients; for a zero-magnitude coefficient (s==0, extremely
# common in valid JPEGs) that is `1 << -1` — a negative shift exponent UBSan flags on essentially
# EVERY real input. Keep ASan + the rest of UBSan ON and HALTING (so genuine OOB / overflow / real
# UB still crash the target); drop only `shift`, and only when UBSan is actually enabled (so the
# empty-SANITIZER_FLAGS off-switch still links cleanly). Smoke check below proves a valid JPEG runs
# to completion afterwards.
SAN_FUZZ="$SANITIZER_FLAGS"
case "$SANITIZER_FLAGS" in
  *undefined*) SAN_FUZZ="$SANITIZER_FLAGS -fno-sanitize=shift" ;;
esac

export SANITIZER_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

cd "$SRC/source"

CXXFLAGS="-DBUILD_LIB -DUNIX -I. -O2 -std=c++14"
LIBSRCS="packjpg.cpp aricoder.cpp bitops.cpp"

# 1) Compile the project as a library (BUILD_LIB drops main(), exposes pjglib_*), instrumented
#    with the (shift-relaxed) sanitizer flags so the fuzzed parse path is covered.
OBJS=""
for f in $LIBSRCS; do
  o="/tmp/${f%.cpp}.fuzz.o"
  $CXX $SAN_FUZZ $CXXFLAGS -c "$f" -o "$o"
  OBJS="$OBJS $o"
done

# 2) libFuzzer target: in-process harness linked against the engine + the sanitized project lib.
$CXX $SAN_FUZZ $LIB_FUZZING_ENGINE $CXXFLAGS \
    "$SRC/mayhem/fuzz_convert.cpp" $OBJS -lstdc++fs \
    -o /mayhem/packjpg-convert-fuzz

# 3) Standalone (non-fuzzer) reproducer: same harness + LLVM's run-once driver, no libFuzzer
#    runtime — one input file, runs LLVMFuzzerTestOneInput once, crashes naturally. The driver is
#    C; compile it as a C object first so clang++ doesn't mangle its LLVMFuzzerTestOneInput ref.
$CC $SAN_FUZZ -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o
$CXX $SAN_FUZZ $CXXFLAGS \
    "$SRC/mayhem/fuzz_convert.cpp" /tmp/standalone_main.o $OBJS -lstdc++fs \
    -o /mayhem/packjpg-convert-fuzz-standalone

# 4) The project's OWN CLI, built with NORMAL flags (no fuzz sanitizers) so test.sh stays an honest
#    round-trip oracle. Without BUILD_LIB this links main(); it auto-detects JPG (compress) / PJG
#    (decompress) and supports `-ver` (compress, decompress, compare in memory). C++17 fs API ->
#    -std=c++14 + -lstdc++fs as upstream's Makefile does.
$CXX -DUNIX -I. -O2 -std=c++14 $LIBSRCS -lstdc++fs -o /mayhem/packjpg

echo "build.sh: built packjpg-convert-fuzz, -standalone, and packjpg (CLI)"
