#!/usr/bin/env bash
#
# mayhem/test.sh — RUN inferno's OWN functional test suite (already compiled by
# mayhem/build.sh via `cargo test --no-run --all-features --all-targets`). This is the
# FULL upstream suite (upstream CI runs `cargo test --locked --all-features --all-targets`
# plus `--doc`): assertion-based integration tests comparing collapse/flamegraph/diff
# output against golden result files under tests/data/*/results, so a no-op/exit(0)
# PATCH FAILS. Emits CTRF.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
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

# RUN the pre-built suite (build.sh already compiled it with normal flags; this
# invocation just runs the cached test binaries). Mirrors upstream CI:
#   cargo test --locked --all-features --all-targets
#   cargo test --locked --all-features --doc
# (doctests are compiled by libtest at run time by design — there is no --no-run form).
OUT="$(mktemp)"
env -u RUSTFLAGS cargo test --locked --all-features --all-targets 2>&1 | tee "$OUT"
env -u RUSTFLAGS cargo test --locked --all-features --doc         2>&1 | tee -a "$OUT"

# Sum every libtest "test result:" line: "test result: ok. N passed; M failed; K ignored; ..."
PASSED=0; FAILED=0; IGN=0
while read -r p f i; do
  PASSED=$((PASSED + p)); FAILED=$((FAILED + f)); IGN=$((IGN + i))
done < <(grep -E '^test result:' "$OUT" \
         | sed -E 's/^test result:[^0-9]*([0-9]+) passed; ([0-9]+) failed; ([0-9]+) ignored.*/\1 \2 \3/')
rm -f "$OUT"

if [ "$PASSED" -eq 0 ] && [ "$FAILED" -eq 0 ]; then
  echo "ERROR: no test-result summary parsed — test binaries missing (build.sh bug)?" >&2
  emit_ctrf "cargo-test" 0 1 0
  exit 1
fi

emit_ctrf "cargo-test" "$PASSED" "$FAILED" "$IGN"
