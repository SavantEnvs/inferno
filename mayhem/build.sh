#!/usr/bin/env bash
#
# mayhem/build.sh — build inferno's cargo-fuzz target (collapse_fuzz) as a sanitized
# libFuzzer binary (OSS-Fuzz Rust path: cargo-fuzz + ASan via RUSTFLAGS), then compile
# (not run) the project's own test suite with normal flags so mayhem/test.sh only RUNS it.
#
# Runs inside the commit image (RUST mayhem/Dockerfile) as `mayhem` in /mayhem.
# The Rust toolchain + cargo registry live at $CARGO_HOME=/opt/toolchains/rust/cargo
# (pinned by the Dockerfile ENV — absolute, $HOME-independent).
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE.
#   - This FIRST build (in CI, online) populates the cargo registry under $CARGO_HOME.
#   - The PATCH re-run resolves crates from that cache. The rlenv runtime exports
#     CARGO_NET_OFFLINE=true for the re-run so cargo won't try to refresh the
#     crates.io index over the (absent) network — so do NOT hard-code `--offline` here.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

cd "$SRC"

# Honor the $SANITIZER_FLAGS contract (SPEC): rustc ignores the clang-oriented
# $SANITIZER_FLAGS, so we map the ASan intent to the rustc flag. ASan is the default
# halting sanitizer; an explicit empty SANITIZER_FLAGS still keeps ASan here.
SANITIZER_FLAGS="${SANITIZER_FLAGS:-}"
RUST_SANITIZER="-Zsanitizer=address"
case "$SANITIZER_FLAGS" in
  *address*|"") : ;;  # ASan requested (default) or no override
esac

# Debug-info contract (SPEC 6.2 item 10): Mayhem triage cannot read DWARF >= 4, and
# LLVM default -Cdebuginfo emits DWARF-5, so pin DWARF < 4 explicitly. Overridable
# via $RUST_DEBUG_FLAGS (the rust arm of the DEBUG_FLAGS contract verify-repo checks).
export RUST_DEBUG_FLAGS="${RUST_DEBUG_FLAGS:--Cdebuginfo=1 -Zdwarf-version=3}"

export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing ${RUST_SANITIZER} ${RUST_DEBUG_FLAGS} -Cforce-frame-pointers"

# libfuzzer-sys compiles its C++ runtime shim via the cc crate; clang defaults to
# DWARF-5 (which Mayhem triage cannot read), so the linked fuzz binary would carry a
# DWARF-5 .debug_info from that object. -Zdwarf-version only governs Rust CUs, so pin
# the C/C++ objects to DWARF-3 too (the cc crate honors CFLAGS/CXXFLAGS).
export CFLAGS="${CFLAGS:-} -gdwarf-3"
export CXXFLAGS="${CXXFLAGS:-} -gdwarf-3"

# Additive mayhem/fuzz/ crate (upstream ships no fuzz/ dir); ports the fork's old
# collapse_fuzz harness over the inferno::collapse::* Folders.
FUZZ_DIR="mayhem/fuzz"
TRIPLE="x86_64-unknown-linux-gnu"

# Discover every target from the crate's fuzz_targets/ dir (one binary per target).
FUZZ_TARGETS=()
for f in "$FUZZ_DIR"/fuzz_targets/*.rs; do
  FUZZ_TARGETS+=("$(basename "${f%.*}")")
done
[ "${#FUZZ_TARGETS[@]}" -gt 0 ] || { echo "ERROR: no fuzz targets under $FUZZ_DIR/fuzz_targets/" >&2; exit 1; }

# The rustc nightly ships a PRECOMPILED ASan runtime (librustc-*_rt.asan.a) whose
# compiler-rt CUs carry DWARF-5 (clang default) — our RUSTFLAGS/CFLAGS only govern
# OUR Rust CUs and the cc-built C/C++, so those runtime CUs would land in the linked
# fuzz binary as DWARF-5 and (being emitted first) fail the DWARF < 4 gate (§6.2 item
# 10). Triage does not need runtime debug symbols; strip debug info from that archive
# (writable: the Dockerfile chowned /opt/toolchains/rust to 2000).
for _asan in $(find /opt/toolchains/rust -name 'librustc-*_rt.asan.a' 2>/dev/null); do
  echo "stripping DWARF-5 debug info from runtime archive: $_asan"
  objcopy --strip-debug "$_asan" "$_asan.tmp" && mv "$_asan.tmp" "$_asan"
done

echo "=== cargo fuzz build (image nightly, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"
echo "targets: ${FUZZ_TARGETS[*]}"

# Use the image's DEFAULT toolchain (the Dockerfile pinned it). A `+toolchain`
# override would make rustup try to install another channel into the locked /opt/rust.
for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  cargo fuzz build --fuzz-dir "$FUZZ_DIR" -O --debug-assertions "$t"
  bin="$SRC/$FUZZ_DIR/target/$TRIPLE/release/$t"
  [ -x "$bin" ] || { echo "ERROR: expected fuzz binary not found at $bin" >&2; exit 1; }
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

# --- Build the project TEST suite with NORMAL (non-sanitized) flags ---
# A clean build so mayhem/test.sh only RUNS the pre-built tests. Clear the fuzz
# RUSTFLAGS (ASan/nightly-fuzzing) for this build; compile (do not run) the full
# upstream suite exactly as upstream CI does: --all-features --all-targets.
echo "=== cargo test --no-run (normal flags, full upstream suite) ==="
# The integration tests read golden inputs from the flamegraph submodule
# (./flamegraph/example-*-stacks.txt*). The CI build context carries only the
# gitlink, so materialize it here (online, first build). The offline PATCH
# re-run is a no-op: the submodule contents already live in the image.
if [ ! -e flamegraph/flamegraph.pl ]; then
  git submodule update --init flamegraph
fi
env -u RUSTFLAGS cargo test --locked --all-features --all-targets --no-run

echo "build.sh complete"
