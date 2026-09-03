#!/usr/bin/env bash
# =============================================================================
# CI for gcb-rtl/integration testbenches.
#
#   convert-tb  (iverilog)          conv_word bit-exact vs. reference     REQUIRED
#   shim-lint   (verilator --lint)  static check of the shim + package    gated *
#   shim-tb     (verilator --binary) full-shim + M_AXIS_CS sink            gated *
#
#   * gated stages need Verilator >= 5. Locally they SKIP when it is missing;
#     set CI_REQUIRE_VERILATOR=1 (the GitHub workflow does) to make a missing or
#     too-old Verilator a FAIL instead.
#
# Every stage runs; a summary is printed; exit is non-zero iff a stage FAILED.
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")"

REQUIRE_VERILATOR="${CI_REQUIRE_VERILATOR:-0}"
mkdir -p sim_out

pass=0; fail=0; skip=0
RESULTS=()

record() {  # name  status  [detail]
    RESULTS+=("$(printf '%-26s %-5s %s' "$1" "$2" "${3:-}")")
    case "$2" in
        PASS) pass=$((pass+1)) ;;
        FAIL) fail=$((fail+1)) ;;
        SKIP) skip=$((skip+1)) ;;
    esac
}

run_stage() {  # name  cmd...
    local name="$1"; shift
    echo "::group::$name"
    local rc=0
    "$@" || rc=$?
    echo "::endgroup::"
    if [ "$rc" -eq 0 ]; then record "$name" PASS; else record "$name" FAIL "exit $rc"; fi
}

have_verilator5() {
    command -v verilator >/dev/null 2>&1 || return 1
    local v maj
    v="$(verilator --version 2>/dev/null | awk '{print $2}')"
    maj="${v%%.*}"
    [ "${maj:-0}" -ge 5 ]
}

VL_WARN=( -Wall -Wno-fatal
          -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM
          -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-CASEINCOMPLETE
          -Wno-PINCONNECTEMPTY -Wno-UNDRIVEN -Wno-TIMESCALEMOD -Wno-BLKSEQ )
VL_SRC=( ../VX_tcu_q1714_convert_pkg.sv stubs/vx_stubs.sv ../VX_tcu_shim_q1714.sv )

# ---- 1. conversion TB (Icarus) — required --------------------------------
if command -v iverilog >/dev/null 2>&1; then
    run_stage "convert-tb (iverilog)" bash run_convert_tb.sh
else
    record "convert-tb (iverilog)" FAIL "iverilog not found"
fi

# ---- 2/3. Verilator-gated stages ---------------------------------------
if have_verilator5; then
    run_stage "shim-lint (verilator)" \
        verilator --lint-only -sv --timing "${VL_WARN[@]}" \
                  +define+SIMULATION +incdir+stubs "${VL_SRC[@]}"
    run_stage "shim-tb (verilator)" bash run_shim_tb.sh
else
    reason="Verilator >= 5 not found"
    if [ "$REQUIRE_VERILATOR" = "1" ]; then
        record "shim-lint (verilator)" FAIL "$reason"
        record "shim-tb (verilator)"   FAIL "$reason"
    else
        record "shim-lint (verilator)" SKIP "$reason"
        record "shim-tb (verilator)"   SKIP "$reason"
    fi
fi

# ---- 4. tile-final SVA check vs the real VX_CFG_* (needs the vortex clone) --
# vortex_integration_notes.md sec 8.4. Needs Verilator >= 5 AND the vortex
# sibling clone (not vendored). Exit 2 from the runner = prerequisites missing
# -> SKIP (a missing external clone is never a CI failure here).
tf_rc=0
bash run_tilefinal_check.sh >/dev/null 2>&1 || tf_rc=$?
case "$tf_rc" in
    0) record "tilefinal-sva (verilator+vortex)" PASS ;;
    2) record "tilefinal-sva (verilator+vortex)" SKIP "verilator>=5 and/or ../../vortex missing" ;;
    *) record "tilefinal-sva (verilator+vortex)" FAIL "exit $tf_rc" ;;
esac

# ---- summary ----------------------------------------------------------
echo
echo "================= integration TB summary ================="
for r in "${RESULTS[@]}"; do echo "  $r"; done
echo "---------------------------------------------------------"
echo "  PASS=$pass  FAIL=$fail  SKIP=$skip"
if [ "$fail" -ne 0 ]; then
    echo "  RESULT: FAIL"
    exit 1
fi
echo "  RESULT: PASS"
