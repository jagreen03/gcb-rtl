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

# ---- stage 3: elaborate VX_tcu_core in a real top + run one WMMA -------
# Build Vortex's VX_tcu_unit_top with $XCONFIGS, bind VX_tcu_tilefinal_sva into
# every VX_tcu_core (VX_tcu_tilefinal_sva_bind.sv), drive one WMMA from
# sim_main.cpp. Elaborating inside the real top is what resolves the nested
# execute_if.data structs that stage 2's standalone lint cannot.
#
# TODO: extend sim_main.cpp to the directed A=all-ones INT8 / B=identity / C=0
# case (D[m][n] = TILE_K) + M_AXIS_CS capture + the {8,16}x{FP8,INT8}x{WGMMA}
# sweep. For now it drives one packet so the SVA's per-instruction A1..A5 run.

# verilator.vlt waiver (third-party lint-off) — @VORTEX_HOME@ substituted here so
# the vortex clone is not touched.
sed "s|@VORTEX_HOME@|$VORTEX|g" "$VORTEX/hw/unittest/verilator.vlt.in" > sim_out/verilator.vlt

VL_TB_INC=(
    +incdir+sim_out
    -I"$VORTEX/sw" -I"$VORTEX/hw"
    -I"$VORTEX/hw/rtl" -I"$VORTEX/hw/dpi" -I"$VORTEX/hw/rtl/libs"
    -I"$VORTEX/hw/rtl/tcu" -I"$VORTEX/hw/rtl/tcu/tfr"
    -I"$VORTEX/hw/rtl/interfaces" -I"$VORTEX/hw/rtl/core"
    -I"$VORTEX/hw/rtl/mem" -I"$VORTEX/hw/rtl/vm" -I"$VORTEX/hw/rtl/fpu"
    -I"$VORTEX/hw/unittest/tcu_unit" -I"$VORTEX/hw/unittest/common"
    -I..
)
VL_TB_FLAGS=( --binary -j 0 --timing --assert --language 1800-2012
              -Wno-fatal -Wno-DECLFILENAME -Wno-REDEFMACRO -Wno-GENUNNAMED
              -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT
              --x-initial unique --x-assign unique
              -DSIMULATION --top-module VX_tcu_unit_top
              --Mdir sim_out/obj_tcu_tf )

if verilator "${VL_TB_FLAGS[@]}" sim_out/verilator.vlt $XCONFIGS "${VL_TB_INC[@]}" \
        "$VORTEX/hw/rtl/VX_gpu_pkg.sv" \
        "$VORTEX/hw/rtl/tcu/VX_tcu_pkg.sv" \
        "$VORTEX/hw/unittest/tcu_unit/VX_tcu_unit_top.sv" \
        ../VX_tcu_tilefinal_sva.sv \
        ../VX_tcu_tilefinal_sva_bind.sv \
        --exe sim_main.cpp \
        > sim_out/tcu_tf_build.log 2>&1; then
    echo "PASS stage 3 build: VX_tcu_unit_top + bound SVA elaborated"
    if sim_out/obj_tcu_tf/VVX_tcu_unit_top > sim_out/tcu_tf_run.log 2>&1 \
       && grep -q "TCU_TILEFINAL: WMMA committed" sim_out/tcu_tf_run.log \
       && ! grep -qE "%Error|Assertion failed|: A[1-5]:" sim_out/tcu_tf_run.log; then
        echo "PASS stage 3 run: $(grep TCU_TILEFINAL sim_out/tcu_tf_run.log)"
    else
        echo "FAIL stage 3 run — see sim_out/tcu_tf_run.log"; tail -20 sim_out/tcu_tf_run.log; exit 1
    fi
else
    echo "PARTIAL stage 3: VX_tcu_unit_top build did not elaborate — see"
    echo "  sim_out/tcu_tf_build.log (last 20 lines):"
    tail -20 sim_out/tcu_tf_build.log
fi

exit 0
