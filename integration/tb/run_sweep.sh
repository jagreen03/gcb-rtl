#!/usr/bin/env bash
# =============================================================================
# vortex_integration_notes.md sec 8.4 config sweep
# =============================================================================
# Runs run_tilefinal_check.sh across {8,16} x {FP8,INT8} x {WGMMA off,on} = 8
# points. Each point forces a full Verilator rebuild (the VX_CFG_* set changes).
# Per-point log in sweep_out/<label>.log; a summary table at the end.
#
# A point is PASS when stage 3 prints "TCU_TILEFINAL: DIRECTED PASS". WGMMA-on
# points may show BUILD-FAIL - VX_tcu_unit_top gains LMEM/descriptor ports the
# minimal harness does not drive; that is a known harness limit, not a marker
# defect, and is reported as such.
#
# Requires Verilator >= 5 + the vortex sibling clone (same as run_tilefinal_check.sh).
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")"
mkdir -p sweep_out

THREADS=(8 16)
FMTS=(INT8 FP8)
WGS=(0 1)

declare -a ROWS
pass=0 notpass=0

for TH in "${THREADS[@]}"; do
  for FMT in "${FMTS[@]}"; do
    for WG in "${WGS[@]}"; do
      lbl="th${TH}_${FMT}_wg${WG}"
      log="sweep_out/${lbl}.log"
      echo ">>> $lbl"
      rm -rf sim_out/obj_tcu_tf
      VX_TFR_THREADS="$TH" VX_TFR_FMT="$FMT" VX_TFR_WGMMA="$WG" \
        bash run_tilefinal_check.sh > "$log" 2>&1
      rc=$?

      if [ "$rc" -eq 0 ] && grep -q "TCU_TILEFINAL: DIRECTED PASS" "$log"; then
        st="PASS"; pass=$((pass+1))
      elif grep -q "^PARTIAL stage 3" "$log"; then
        st="BUILD-FAIL"; notpass=$((notpass+1))
      elif grep -q "^SKIP" "$log"; then
        st="SKIP"; notpass=$((notpass+1))
      else
        st="RUN-FAIL"; notpass=$((notpass+1))
      fi

      counts="$(grep -oE 'beats_in=[0-9]+ +tile_final_uops=[0-9]+ +tile_final_result_beats=[0-9]+' "$log" | tail -1)"
      params="$(grep -oE 'TCU_UOPS=[0-9]+ +tile_final/instr=[0-9]+ +TILE_K=[0-9]+' "$log" | tail -1)"
      ROWS+=("$(printf '%-16s %-11s %-46s %s' "$lbl" "$st" "${params:--}" "${counts:--}")")
    done
  done
done

echo
echo "==================== sec 8.4 config sweep ===================="
printf '  %-16s %-11s %-46s %s\n' "config" "status" "params" "retire counts"
for r in "${ROWS[@]}"; do echo "  $r"; done
echo "------------------------------------------------------------"
echo "  PASS=$pass  NOT-PASS=$notpass  (of $((pass+notpass)))"
if [ "$notpass" -eq 0 ]; then echo "  RESULT: PASS"; else echo "  RESULT: PARTIAL"; fi
