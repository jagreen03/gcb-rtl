# gcb-rtl / scripts

## `build.tcl` — out-of-context synthesis baseline

Headless OOC synthesis of `greencoyote_top` for the AMD Alveo U55C
(`xcu55c-fsvh2892-2L-e`). Use it to check that the design maps and to establish
a baseline setup-slack number on the 300 MHz `user_clk` before place-and-route.

```sh
# from the repo root
vivado -mode batch -source scripts/build.tcl \
       -log build/logs/vivado.log -journal build/logs/vivado.jou
```

Overrides (positional Tcl args, or environment variables):

```sh
vivado -mode batch -source scripts/build.tcl -tclargs <part> <top> <period_ns>
#   or:  GCB_PART=... GCB_TOP=... GCB_PERIOD_NS=... vivado -mode batch -source scripts/build.tcl
```

### Outputs (`build/`, git-ignored)

| File | |
|---|---|
| `checkpoints/post_synth.dcp` | post-synth checkpoint for downstream P&R (`open_checkpoint`) |
| `reports/utilization_synth.rpt` | LUT / FF / BRAM / DSP footprint (flat) |
| `reports/utilization_synth_hier.rpt` | same, broken down by instance (depth 3) |
| `reports/timing_synth.rpt` | `report_timing_summary` — WNS/TNS, unconstrained paths, `check_timing` |
| `reports/timing_worst_paths.rpt` | 20 worst paths, full clock-expanded |
| `reports/drc_synth.rpt` | synth-stage DRC |

Exit status: `0` ok · `1` synth error · `2` setup error · `3` negative setup WNS.

### Constraints

`build.tcl` reads **`constraints/greencoyote_ooc.xdc`** (timing only: the
`user_clk` definition plus loose I/O budgets). It deliberately does **not** read
`constraints/greencoyote_bay.xdc` — that file carries `PACKAGE_PIN` /
`IOSTANDARD` / `SLR` / bitstream properties and placeholder pin names
(`REPLACE_WITH_LA02_P …`) that are meaningless in OOC (no I/O buffers) and would
hard-error the run. Fold `greencoyote_bay.xdc` back in at the implementation /
Vitis-platform stage once real U55C package pins have been filled in.
