#!/usr/bin/env bash
# =============================================================================
# GreenCoyote-Bay <-> Vortex 3.0 TCU integration configuration target
# =============================================================================
# The VX_CFG_* set the tile-final / carry-save integration is verified against
# (carry_save_streaming_contract.md sec 8 item 5; vortex_integration_notes.md
# sec 6, sec 8.4). Vortex takes build-time overrides as `CONFIGS="-D..."` on the
# make line (ci/blackbox.sh); this file is the single source of that string.
#
# Source it, then use "$VX_TFR_CONFIGS" / "$VX_TFR_THREADS":
#   source integration/tcu_tfr_config.sh
#   CONFIGS="$VX_TFR_CONFIGS" make -C <vortex>/hw ...
# =============================================================================

# Thread count for the integration build. The shipped VX_config.toml runs the
# TCU at NUM_THREADS=4 toy dims; the optical cell wants 8 lanes.
VX_TFR_THREADS="${VX_TFR_THREADS:-8}"

# Foundational processor axis. VX_CFG_XLEN is an [[enum]] with no default in
# VX_config.toml; every Vortex build site adds "-DVX_CFG_XLEN=$(XLEN)" to the
# gen_config.py --cflags (see hw/*/Makefile, XLEN defaults to 32 in configure).
# gen_config.py raises ValueError: Undefined key 'VX_CFG_XLEN' without it.
# FLEN / FPU_TYPE have expr: defaults in the toml and resolve once XLEN is set.
VX_TFR_XLEN="${VX_TFR_XLEN:-32}"     # 32 (U55C target) | 64

# Config sweep axis (vortex_integration_notes.md sec 8.4): {8,16} x {FP8,INT8} x
# {WGMMA off,on}. Override before sourcing to pick a sweep point, e.g.
#   VX_TFR_THREADS=16 VX_TFR_FMT=INT8 VX_TFR_WGMMA=1 source integration/tcu_tfr_config.sh
VX_TFR_FMT="${VX_TFR_FMT:-FP8}"      # FP8 | INT8
VX_TFR_WGMMA="${VX_TFR_WGMMA:-0}"    # 0 | 1

_tfr_defs=(
    "-DVX_CFG_XLEN=${VX_TFR_XLEN}"   # foundational axis (no toml default)
    "-DVX_CFG_EXT_TCU_ENABLE"
    "-DVX_CFG_TCU_TYPE=TFR"          # Ten-Four Reduction FEDP
    "-DVX_CFG_TCU_USE_DSP=1"         # U55C build maps FEDP mults to DSP48
    "-DVX_CFG_NUM_THREADS=${VX_TFR_THREADS}"
)

case "$VX_TFR_FMT" in
    FP8)  _tfr_defs+=( "-DVX_CFG_TCU_FP8_ENABLE" ) ;;
    INT8) _tfr_defs+=( "-DVX_CFG_TCU_INT8_ENABLE" ) ;;
    *)    echo "tcu_tfr_config.sh: VX_TFR_FMT must be FP8 or INT8" >&2; return 1 2>/dev/null || exit 1 ;;
esac

[ "$VX_TFR_WGMMA" = "1" ] && _tfr_defs+=( "-DVX_CFG_TCU_WGMMA_ENABLE" )

# MX is optional (vortex_integration_notes.md sec 6); leave it off for the
# baseline so the shim self-derives the block exponent (contract sec 4.2).

export VX_TFR_CONFIGS="${_tfr_defs[*]}"
export VX_TFR_THREADS VX_TFR_FMT VX_TFR_WGMMA VX_TFR_XLEN

if [ "${1:-}" = "--print" ]; then
    echo "VX_TFR_XLEN    = $VX_TFR_XLEN"
    echo "VX_TFR_THREADS = $VX_TFR_THREADS"
    echo "VX_TFR_FMT     = $VX_TFR_FMT"
    echo "VX_TFR_WGMMA   = $VX_TFR_WGMMA"
    echo "VX_TFR_CONFIGS = $VX_TFR_CONFIGS"
fi
