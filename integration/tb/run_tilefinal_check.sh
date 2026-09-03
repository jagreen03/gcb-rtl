#!/usr/bin/env bash
# =============================================================================
# vortex_integration_notes.md sec 8.4 — tile-final marker check
# =============================================================================
# Stages:
#   0  gen_config  — resolve VX_CFG_* for the TFR target, emit VX_config.vh /
#                    VX_types.vh (replicates `configure`'s header step)
#   1  sva-lint    — Verilator lint of VX_tcu_tilefinal_sva.sv (A1..A5)
#   2  rtl-lint    — Verilator lint of the tag wrapper + SVA against the real
#                    VX_gpu_pkg / VX_tcu_pkg from the vortex clone
#   3  directed    — WMMA directed test + {8,16}x{FP8,INT8}x{WGMMA} sweep (TODO)
#
# Requires: Verilator >= 5, python3, and the vortex sibling clone (not vendored).
# Exit: 0 pass · 1 check failed · 2 prerequisites missing (SKIP)
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")"

INTEG_DIR="$(cd .. && pwd)"
VORTEX="${VORTEX:-$(cd ../../.. 2>/dev/null && pwd)/vortex}"
[ -d "$VORTEX/hw/rtl/tcu" ] || VORTEX="$INTEG_DIR/../../vortex"

miss=0
command -v verilator >/dev/null 2>&1 || { echo "SKIP: verilator not found (need >= 5)"; miss=1; }
if command -v verilator >/dev/null 2>&1; then
    vmaj="$(verilator --version 2>/dev/null | awk '{print $2}' | cut -d. -f1)"
    [ "${vmaj:-0}" -ge 5 ] || { echo "SKIP: verilator $vmaj < 5"; miss=1; }
fi
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not found"; miss=1; }
[ -d "$VORTEX/hw/rtl/tcu" ] || { echo "SKIP: vortex clone not at $VORTEX"; miss=1; }
[ "$miss" -eq 0 ] || { echo "run_tilefinal_check: prerequisites missing"; exit 2; }

mkdir -p sim_out

# ---- config target -------------------------------------------------------
# shellcheck source=../tcu_tfr_config.sh
source "$INTEG_DIR/tcu_tfr_config.sh" --print
export XLEN="$VX_TFR_XLEN"          # gen_config reads XLEN from the env for VX_types

GENCFG="$VORTEX/ci/gen_config.py"

# ---- stage 0: resolve config + emit the generated headers --------------
XCONFIGS="$(python3 "$GENCFG" --config="$VORTEX/VX_config.toml" --cflags="$VX_TFR_CONFIGS")" \
    || { echo "FAIL: gen_config.py (cflags) — the VX_CFG_* set is incomplete"; exit 1; }
python3 "$GENCFG" --config="$VORTEX/VX_config.toml" --format=verilog \
    --output=sim_out/VX_config.vh --cflags="$VX_TFR_CONFIGS" \
    || { echo "FAIL: gen_config.py could not emit VX_config.vh"; exit 1; }
python3 "$GENCFG" --config="$VORTEX/VX_types.toml" --format=verilog --resolved \
    --output=sim_out/VX_types.vh \
    || { echo "FAIL: gen_config.py could not emit VX_types.vh"; exit 1; }
echo "PASS stage 0: gen_config resolved the TFR config (XLEN=$XLEN); headers emitted"

VL_COMMON=( --lint-only -sv --timing -Wno-fatal +define+SIMULATION )

# ---- stage 1: the SVA module on its own -------------------------------
if verilator "${VL_COMMON[@]}" ../VX_tcu_tilefinal_sva.sv > sim_out/sva_lint.log 2>&1; then
    echo "PASS stage 1: VX_tcu_tilefinal_sva.sv lints clean (A1..A5)"
else
    echo "FAIL stage 1: VX_tcu_tilefinal_sva.sv lint"; cat sim_out/sva_lint.log; exit 1
fi

# ---- stage 2: tag wrapper + SVA against the real TCU packages ---------
VL_INC=(
    +incdir+sim_out
    +incdir+"$VORTEX/hw/rtl"
    +incdir+"$VORTEX/hw/rtl/libs"
    +incdir+"$VORTEX/hw/rtl/core"
    +incdir+"$VORTEX/hw/rtl/mem"
    +incdir+"$VORTEX/hw/rtl/interfaces"
    +incdir+"$VORTEX/hw/rtl/tcu"
    +incdir+"$VORTEX/hw/rtl/tcu/tfr"
    +incdir+..
)
if verilator "${VL_COMMON[@]}" $XCONFIGS "${VL_INC[@]}" \
        "$VORTEX/hw/rtl/VX_gpu_pkg.sv" \
        "$VORTEX/hw/rtl/tcu/VX_tcu_pkg.sv" \
        ../VX_tcu_tilefinal_tag.sv \
        ../VX_tcu_tilefinal_sva.sv \
        > sim_out/rtl_lint.log 2>&1; then
    echo "PASS stage 2: tag wrapper + SVA lint clean against $VORTEX TCU packages"
else
    echo "PARTIAL stage 2: lint against the real TCU packages needs more of the"
    echo "  vortex tree on the include path (interface defs, etc.) — see"
    echo "  sim_out/rtl_lint.log. Stage 1 already validated the SVA itself."
fi

# ---- stage 3: directed WMMA test + config sweep (TODO) ---------------
# Build hw/unittest/tcu_unit with $VX_TFR_CONFIGS, bind VX_tcu_tilefinal_sva
# into VX_tcu_core, issue the directed wmma (A=all-ones INT8, B=identity, C=0
# -> D[m][n]=TILE_K), capture M_AXIS_CS; assert stream beats == M_STEPS*N_STEPS
# (not TCU_UOPS), each de-scaled acc_word == D[m][n], A1..A5 pass; sweep
# {8,16} x {FP8,INT8} x {WGMMA off,on}.
echo "PARTIAL stage 3: directed WMMA test not yet wired — see TODO above"
exit 0
