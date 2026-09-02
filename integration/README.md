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

**Wiring:** `VX_tcu_core` → `VX_tcu_tilefinal_tag` → `VX_tcu_shim_q1714` →
`M_AXIS_CS` → (pilot) per-lane async FIFO. The tag wrapper's `result_if` still
feeds `VX_lane_gather` / `commit_if` unchanged — the shim consumes a copy.

Run the conversion test: `bash tb/run_convert_tb.sh` (currently
`checks=1800084 errors=0`).

**Status:** draft. Compile and check against the chosen `VX_CFG_*` set using the
SVA + directed test in `vortex_integration_notes.md` §8.4 before wiring the shim.
Framing: civil compute-integration engineering.
