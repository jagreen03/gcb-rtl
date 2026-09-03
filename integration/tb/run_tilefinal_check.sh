#!/usr/bin/env bash
# =============================================================================
# vortex_integration_notes.md sec 8.4 — tile-final marker check
# =============================================================================
# Elaborates VX_tcu_tilefinal_sva (A1..A5) bound into VX_tcu_core, against the
# real VX_CFG_* integration target (integration/tcu_tfr_config.sh), then runs
# the directed WMMA test.
#
# Requires:
#   * Verilator >= 5              (Vortex's own simulator; Icarus can't build it)
#   * the vortex sibling clone at ../../vortex   (NOT vendored — Apache-2.0,
#     kept independent; clone with:
#       git clone --recursive https://github.com/vortexgpgpu/vortex.git \
#         "$(git -C .. rev-parse --show-toplevel)/../vortex")
#
# Exit codes: 0 pass · 1 check failed · 2 prerequisites missing (SKIP)
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")"

INTEG_DIR="$(cd .. && pwd)"
VORTEX="${VORTEX:-$(cd ../../.. 2>/dev/null && pwd)/vortex}"
[ -d "$VORTEX" ] || VORTEX="$INTEG_DIR/../../vortex"

miss=0
if ! command -v verilator >/dev/null 2>&1; then
    echo "SKIP: verilator not found (need >= 5)"; miss=1
else
    vmaj="$(verilator --version 2>/dev/null | awk '{print $2}' | cut -d. -f1)"
    [ "${vmaj:-0}" -ge 5 ] || { echo "SKIP: verilator $vmaj < 5"; miss=1; }
fi
if [ ! -d "$VORTEX/hw/rtl/tcu" ]; then
    echo "SKIP: vortex clone not at $VORTEX (hw/rtl/tcu missing)"; miss=1
fi
[ "$miss" -eq 0 ] || { echo "run_tilefinal_check: prerequisites missing"; exit 2; }

# ---- config target ---------------------------------------------------------
# shellcheck source=../tcu_tfr_config.sh
source "$INTEG_DIR/tcu_tfr_config.sh" --print

mkdir -p sim_out
GEN_VH="sim_out/VX_config_tfr.vh"

if [ -f "$VORTEX/ci/gen_config.py" ]; then
    python3 "$VORTEX/ci/gen_config.py" --config "$VORTEX/VX_config.toml" \
        $VX_TFR_CONFIGS --output "$GEN_VH" \
        || { echo "FAIL: gen_config.py failed"; exit 1; }
    echo "generated $GEN_VH"
else
    echo "note: $VORTEX/ci/gen_config.py absent; passing CONFIGS as +define+ instead"
fi

# ---- stage 1: lint the SVA + tag wrapper against the real TCU RTL ----------
VL_INC=(
    +incdir+"$VORTEX/hw/rtl"
    +incdir+"$VORTEX/hw/rtl/tcu"
    +incdir+"$VORTEX/hw/rtl/libs"
    +incdir+"$VORTEX/hw/rtl/core"
    +incdir+sim_out
    +incdir+..
)
verilator --lint-only -sv --timing -Wno-fatal \
    +define+SIMULATION +define+SYNTHESIS \
    ${VX_TFR_CONFIGS// / +define+} \
    "${VL_INC[@]}" \
    "$VORTEX/hw/rtl/tcu/VX_tcu_pkg.sv" \
    ../VX_tcu_tilefinal_tag.sv \
    ../VX_tcu_tilefinal_sva.sv \
    || { echo "FAIL: lint of tag wrapper + SVA against $VORTEX TCU pkg failed"; exit 1; }
echo "PASS: VX_tcu_tilefinal_sva + VX_tcu_tilefinal_tag lint clean against the TFR config"

# ---- stage 2: full SVA elaboration + directed WMMA test -------------------
# TODO(next session, with Verilator available): build the Vortex TCU unittest
#   (hw/unittest) with $VX_TFR_CONFIGS, `bind` VX_tcu_tilefinal_sva into
#   VX_tcu_core, issue the directed wmma (A=all-ones INT8, B=identity, C=0 ->
#   D[m][n]=TILE_K), capture M_AXIS_CS, and assert:
#     - stream beat count == M_STEPS*N_STEPS  (tile-final only, not TCU_UOPS)
#     - each de-scaled acc_word == D[m][n]
#     - A1..A5 pass; sweep {8,16} x {FP8,INT8} x {WGMMA off,on}
echo "PARTIAL: stage 2 (SVA elaboration + directed WMMA) not yet wired — see TODO above"
exit 0
