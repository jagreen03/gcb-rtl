# Post-route OOC baseline — greencoyote_top

Reference snapshot of a clean out-of-context place & route, kept as a fixed
point for future timing/resource regressions.

| | |
|---|---|
| Source commit | `652e21e` (fix(rtl): DEFECT-002 output wire compliance, DEFECT-004 0x90/0x98 bit-pad corrections, BRAM/EXEC strobe auto-clears) |
| Generated | 2026-09-02, Vivado 2024.2 (win64) |
| Flow | `scripts/build.tcl` then `scripts/impl.tcl` |
| Part | `xcu55c-fsvh2892-2L-e` (Alveo U55C), OOC mode |
| Clock | `user_clk` 3.333 ns / 300 MHz (`constraints/greencoyote_ooc.xdc`) |

Supersedes the pre-fix baseline (`974b705`, +0.362 ns WNS / 608 LUT). The
DEFECT-004 read-decoder cleanup trimmed 6 LUTs; the unchanged gain-trim → DSP →
DAC critical path re-placed with ~0.1 ns less setup margin (P&R variance, not new
logic on the path). DSP count is unchanged.

## Timing — all constraints met

| Metric | Value | Failing endpoints |
|---|---|---|
| Setup WNS | **+0.261 ns** | 0 / 1290 |
| Hold WHS | **+0.043 ns** | 0 / 1290 |
| Pulse-width WPWS | +1.391 ns | 0 / 698 |

Worst setup path: `u_pilot_regs/r_trim_ch4_reg[0]` → DSP48E2 multiply
(`buf_data[4]·trim_ch[4]`) → CARRY8 ×2 (dark-offset subtract + precision pack)
→ LUT2 → LUT5 → `u_sequencer/dac_data_reg[4][9]`. 3.052 ns data path
(logic 2.049 ns, route 1.003 ns), 10 logic levels — the combinational
gain-trim / normalize / pack cloud into the DAC register.

## Resources

| | Used | Avail | Util |
|---|---|---|---|
| CLB LUT | 602 | 1,303,680 | 0.05% |
| CLB register (FF) | 698 | 2,607,360 | 0.03% |
| CARRY8 | 25 | 162,960 | 0.02% |
| DSP48E2 | 8 | 9,024 | 0.09% |
| Block RAM / URAM | 0 / 0 | 2,016 / 960 | — |

DSP DRC advisories (`DPIP-2`, `DPOP-3/4`) are expected: the per-channel
`buf_data·trim_ch` multiplies run unregistered inside `always_comb`.

## Power

Total 3.293 W = 3.273 W device static (whole-chip leakage, temp grade E)
+ **0.020 W dynamic**. Vectorless estimate, confidence Medium.

## Files

| File | |
|---|---|
| `post_route.dcp` | routed checkpoint (`open_checkpoint` for downstream work) |
| `timing_route.rpt` | `report_timing_summary` (min_max, unconstrained, check_timing) |
| `timing_route_worst_paths.rpt` | 20 worst paths, full clock-expanded |
| `utilization_route.rpt` | resource breakdown |
| `clock_utilization_route.rpt` | clock net / BUFG usage |
| `drc_route.rpt` | post-route DRC |
| `power_route.rpt` | vectorless power estimate |

Regenerate: `vivado -mode batch -source scripts/build.tcl` then
`vivado -mode batch -source scripts/impl.tcl` (outputs land in `build/`,
copy the `*_route.*` set here to refresh this baseline).
