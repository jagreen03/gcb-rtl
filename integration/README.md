# gcb-rtl/integration — Vortex-side staging RTL

Draft RTL that belongs in the **Vortex 3.0 tree**, not the GreenCoyote-Bay pilot.
Tracked here so it is reviewed and versioned alongside the contract it
implements; **never synthesised into the pilot** — `scripts/build.tcl` globs only
`rtl/*.sv` and `rtl/generated/*.sv`, so this directory is outside the build.

| File | Implements | Spec |
|------|-----------|------|
| `VX_tcu_tilefinal_tag.sv` | Inline wrapper around `VX_tcu_core` that emits `is_tile_final` and `fmt_d_out` (aligned to `result_if.valid`) by mirroring the core's `mdata_queue` push/pop ordering. Gates the optical-reduction stream to the last-K accumulator writeback per (m,n) sub-tile. | `gcb-spec/vortex_integration_notes.md` §8; `gcb-spec/carry_save_streaming_contract.md` §8–§9 |
| `VX_tcu_q1714_convert_pkg.sv` | Dependency-free package holding the bit-exact fp32/int32 → Q17.14 arithmetic (`conv_word`). One source of truth for the shim and the testbench. | — |
| `VX_tcu_shim_q1714.sv` | Consumes the tag wrapper's `result_if` + `is_tile_final` + `fmt_d`; converts each PE word (via `conv_word`) to Q17.14 two's-complement with rne rounding, saturation, and `nan_inf` / `clamp` flags; serialises `NUM_LANES` beats per tile-final record onto one `M_AXIS_CS` AXI4-Stream master. | `gcb-spec/carry_save_streaming_contract.md` §4.1–§4.2, §6; `gcb-spec/vortex_integration_notes.md` §5 |
| `tb/tb_VX_tcu_q1714_convert.sv` | Standalone bit-exact test: `conv_word` vs. an independent real/longint reference model (directed corners + ~1.8M randomized vectors, RNE and TRUNC). `tb/run_convert_tb.sh` (Icarus ≥ 11). | — |
| `tb/tb_VX_tcu_shim_q1714.sv` | Full-shim TB: `result_if` driver + `M_AXIS_CS` sink with random `TREADY` backpressure + ring-buffer scoreboard. Checks per tile-final record: exactly `NUM_LANES` beats, `TDATA` == golden `conv_word`, `TUSER` = `{nan,ovf,lane}`, `TLAST` last-only, `TID`/`TKEEP`, in order; non-final records emit **zero** beats; `result_if.ready` low mid-record. `tb/run_shim_tb.sh` — **Verilator ≥ 5** (Vortex's sim; Icarus 11 has no interface-port support). `tb/stubs/` holds minimal `VX_define.vh` / `VX_result_if` / `VX_fifo_queue` / `VX_*_pkg`. | `gcb-spec/carry_save_streaming_contract.md` §6 |
| `tcu_tfr_config.sh` | The `VX_CFG_*` integration target — sourced to get `VX_TFR_CONFIGS` (`-DVX_CFG_EXT_TCU_ENABLE -DVX_CFG_TCU_TYPE=TFR -DVX_CFG_TCU_USE_DSP=1 -DVX_CFG_NUM_THREADS=…` + FP8/INT8 + optional WGMMA). Sweep axes via `VX_TFR_THREADS` / `VX_TFR_FMT` / `VX_TFR_WGMMA`. | `gcb-spec/carry_save_streaming_contract.md` §8; `vortex_integration_notes.md` §6, §8.4 |
| `VX_tcu_tilefinal_sva.sv` | Bind-able SVA checker (A1–A5 of `vortex_integration_notes.md` §8.4) for the `step_k == BLOCK_K_STEPS-1` marker. Standalone-lints clean; elaborated live via the bind below. | `gcb-spec/vortex_integration_notes.md` §8.4 |
| `VX_tcu_tilefinal_sva_bind.sv` | `bind VX_tcu_core VX_tcu_tilefinal_sva …` — kept out of the vortex tree; added to the Verilator source list by the runner. Reaches the core's internal predicates and `execute_if.data.header.eop` (only resolvable inside a real top). | `gcb-spec/vortex_integration_notes.md` §8.4 |
| `tb/sim_main.cpp` | Verilator `--exe` driver for `VX_tcu_unit_top`, two phases: **P1** one directed INT8 WMMA (A = B = all-ones INT8, C = 0) → checks every committed `D` lane (int32) == `TILE_K`; **P2** drives `TCU_UOPS` dispatches as one instruction with `step_k` stepped K-outer, so the bound SVA reports `beats_in == TCU_UOPS` and `tile_final == TCU_M_STEPS·TCU_N_STEPS` (A1/A2/A4). `VX_tcu_unit_top` has no `VX_uop_sequencer`, so P2 supplies the uop stream the sequencer would emit. DPI (`gcb_tf_event`, `+define+GCB_TF_DPI`) carries the SVA counts to C++. | `gcb-spec/vortex_integration_notes.md` §8.4 |
| `tb/run_tilefinal_check.sh` | Runs the §8.4 check in stages: **0** `gen_config` resolves the TFR `VX_CFG_*` + emits `VX_config.vh`/`VX_types.vh`; **1** Verilator lints `VX_tcu_tilefinal_sva.sv` (A1–A5); **2** standalone lint of the tag wrapper (PARTIAL — interface ports need a real top); **3** `verilator --binary` builds `VX_tcu_unit_top` with the SVA bound into every `VX_tcu_core` and runs one WMMA through `sim_main.cpp`. Exit 2 = prerequisites missing (SKIP). Stages 0, 1, 3 pass under Verilator 5.032 + the vortex clone. **TODO** in stage 3: directed A=all-ones INT8 / B=identity / C=0 case + `M_AXIS_CS` capture + `{8,16}×{FP8,INT8}×{WGMMA}` sweep. | `gcb-spec/vortex_integration_notes.md` §8.4 |

**Wiring:** `VX_tcu_core` → `VX_tcu_tilefinal_tag` → `VX_tcu_shim_q1714` →
`M_AXIS_CS` → (pilot) per-lane async FIFO. The tag wrapper's `result_if` still
feeds `VX_lane_gather` / `commit_if` unchanged — the shim consumes a copy.

**CI:** `bash tb/ci.sh` runs every stage and prints a summary —
`convert-tb` (Icarus, required), `shim-lint` + `shim-tb` (Verilator ≥ 5),
`tilefinal-sva` (Verilator ≥ 5 **and** the `../../vortex` clone).
Verilator stages SKIP locally when it is absent; `CI_REQUIRE_VERILATOR=1` makes
`shim-*` a FAIL. `tilefinal-sva` SKIPs whenever the vortex clone is absent (an
external, non-vendored dependency — never a CI failure here).
`.github/workflows/integration-tb.yml` runs `ci.sh` on `integration/**`,
`rtl/**` and `sim/**` changes with both simulators installed.

Individual runners: `bash tb/run_convert_tb.sh` (Icarus, currently
`checks=1800084 errors=0`), `bash tb/run_shim_tb.sh` (Verilator ≥ 5). The
full-shim test runs green in the GitHub Actions `ubuntu-24.04` job
(`shim-lint` + `shim-tb` PASS: 1500 records under random `TREADY`, 8704
`M_AXIS_CS` beats, 0 scoreboard errors); it is not run in the Icarus-only
local authoring environment, which lacks SV interface-port support.

**Status:** draft. The `VX_CFG_*` target (`tcu_tfr_config.sh`, `XLEN=32` +
INT8/TCU flags), the §8.4 SVA + bind, and the staged runner are in place.
`run_tilefinal_check.sh` stages 0, 1, 3 pass under Verilator 5.032 + the
`../../vortex` clone: config resolves, SVA lints clean, and the **directed test
passes** — `D == TILE_K` (8) on every committed lane, and the bound SVA counts
`beats_in = 32 = TCU_UOPS` with `tile_final = 8 = TCU_M_STEPS·TCU_N_STEPS`
(A1/A2/A4). Stage 2 (tag-wrapper standalone lint) stays PARTIAL. **TODO:** wire
`VX_tcu_tilefinal_tag` in for A3/A5, and the `{8,16}×{FP8,INT8}×{WGMMA}` sweep.
Framing: civil compute-integration engineering.
