#!/usr/bin/env bash
#
# packJPG/mayhem/test.sh — RUN packJPG's lossless round-trip as a known-answer oracle → CTRF.
#
# packJPG's contract is LOSSLESS recompression: JPEG -> PJG -> JPEG must reproduce the ORIGINAL
# JPEG byte-for-byte. That is a real behavioral oracle: a PATCH that "fixes" a crash by making the
# converter a no-op / exit(0) / emit garbage breaks the round-trip and FAILS here — "ran without
# crashing" is NOT enough.
#
# For each committed seed we assert TWO things:
#   1. round-trip: compress to .pjg, decompress back, and `cmp` the result byte-identical to the
#      original (the strongest known-answer check).
#   2. -ver (built-in verify): packjpg compresses, internally decompresses, compares in memory, and
#      reports the error count; we assert it prints "0 error(s)".
# packjpg (the CLI) is built by mayhem/build.sh with the project's NORMAL flags (no fuzz sanitizers)
# so this stays an honest functional oracle. This script only RUNS it — it never compiles.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

BIN=/mayhem/packjpg
[ -x "$BIN" ] || { echo "missing $BIN — run mayhem/build.sh first" >&2; exit 2; }

SEEDS=( "$SRC"/mayhem/corpus/*.jpg )
[ -e "${SEEDS[0]}" ] || { echo "no seed JPEGs in mayhem/corpus — cannot run round-trip oracle" >&2; exit 2; }

passed=0; failed=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

for seed in "${SEEDS[@]}"; do
  name="$(basename "$seed")"

  # --- Test 1: lossless round-trip (JPEG -> PJG -> JPEG, byte-identical) ---
  rm -f "$WORK"/*.jpg "$WORK"/*.pjg
  cp "$seed" "$WORK/rt.jpg"
  "$BIN" "$WORK/rt.jpg" -np >/dev/null 2>&1                 # compress -> rt.pjg
  rm -f "$WORK/rt.jpg"
  "$BIN" "$WORK/rt.pjg" -np >/dev/null 2>&1                 # decompress -> rt.jpg
  if [ -f "$WORK/rt.jpg" ] && cmp -s "$seed" "$WORK/rt.jpg"; then
    echo "roundtrip $name: PASS (byte-identical)"; passed=$((passed+1))
  else
    echo "roundtrip $name: FAIL (not byte-identical to original)"; failed=$((failed+1))
  fi

  # --- Test 2: built-in -ver verify reports zero errors ---
  cp "$seed" "$WORK/ver.jpg"
  out="$("$BIN" -ver "$WORK/ver.jpg" -np 2>&1)"
  if echo "$out" | grep -q "0 error(s)"; then
    echo "verify   $name: PASS (0 errors)"; passed=$((passed+1))
  else
    echo "verify   $name: FAIL ($(echo "$out" | grep -oE '[0-9]+ error\(s\)' || echo 'no error count'))"; failed=$((failed+1))
  fi
done

emit_ctrf "packjpg-roundtrip-kat" "$passed" "$failed"
