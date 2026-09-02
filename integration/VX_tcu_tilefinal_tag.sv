// =============================================================================
// GreenCoyote-Bay — Ten-Four tile-final tag (Vortex-side staging RTL)
// Project: ODIN_Bridge / Cascaded Optical Reduction Fabric
// =============================================================================
// Draft reference implementation of the tile-final marker hook specified in
//   gcb-spec/vortex_integration_notes.md  §8.3
//   gcb-spec/carry_save_streaming_contract.md  §8 (item 4), §9
//
// This module belongs in the VORTEX tree, not the pilot OOC build. It lives
// under gcb-rtl/integration/ only as tracked staging; scripts/build.tcl globs
// rtl/*.sv and rtl/generated/*.sv, so it is never synthesised into the pilot.
//
// Purpose
// -------
// VX_tcu_core.result_if fires once per compute uop; every K-step of an MMA
// instruction writes the C tile back. Only the last-K writeback of each (m,n)
// sub-tile is the fully-accumulated value the optical reduction must consume.
// There is no ready-made marker on result_if (header.eop is a SIMD-packet flag;
// op_args.tcu.is_last_uop is WGMMA-only and marks a single sub-tile). The usable
// primitive is step_k == BLOCK_K_STEPS-1, which lives on execute_if and is not
// piped past the FEDP latency.
//
// This module sits inline around VX_tcu_core (execute_if in/out, result_if
// in/out, both passed through untouched) and emits `is_tile_final`, aligned to
// result_out.valid, by mirroring the core's own header-FIFO ordering:
//   push a 1-bit tag on every event equal to VX_tcu_core `fedp_enqueue`
//   pop it on every event equal to VX_tcu_core `fedp_result_fire`
// A same-depth, same-OUT_REG mirror of VX_tcu_core's `mdata_queue` therefore
// stays bit-aligned with the compute result beats. Setup-uop result beats
// (WGMMA descriptor setup) carry no FEDP payload: they neither push nor pop the
// tag FIFO and force `is_tile_final = 0`.
//
// Integration: instantiate in place of VX_tcu_core in VX_tcu_unit's g_blocks
// loop, wiring the inner core through this module's *_core ports, and route
// `is_tile_final` to the fp32/int32 -> Q17.14 shim (it becomes
// M_AXIS_CS.TVALID = result_out.valid && is_tile_final, with the shim consuming
// non-final beats without streaming them).
//
// Verification: run the SVA in gcb-spec/vortex_integration_notes.md §8.4 and
// the assertions at the foot of this file against the chosen VX_CFG_* set.
// =============================================================================

`include "VX_define.vh"

module VX_tcu_tilefinal_tag import VX_gpu_pkg::*, VX_tcu_pkg::*; #(
    parameter `STRING INSTANCE_ID = ""
) (
    input  wire          clk,
    input  wire          reset,

    // ---- external interfaces (face VX_tcu_unit) ----------------------------
    VX_execute_if.slave  execute_if,        // from lane_dispatch / core_execute_if
    VX_result_if.master  result_if,         // to per_block_result_if / lane_gather
    output wire          is_tile_final,     // aligned to result_if.valid

    // ---- internal interfaces (face the wrapped VX_tcu_core) ---------------
    VX_execute_if.master execute_core_if,   // -> VX_tcu_core.execute_if
    VX_result_if.slave   result_core_if     // <- VX_tcu_core.result_if
);
    `UNUSED_SPARAM (INSTANCE_ID)

    // -------------------------------------------------------------------------
    // Straight passthrough — this module adds a sideband, never backpressure.
    // -------------------------------------------------------------------------
    assign execute_core_if.valid = execute_if.valid;
    assign execute_core_if.data  = execute_if.data;
    assign execute_if.ready      = execute_core_if.ready;

    assign result_if.valid       = result_core_if.valid;
    assign result_if.data        = result_core_if.data;
    assign result_core_if.ready  = result_if.ready;

    // -------------------------------------------------------------------------
    // Timing constants — mirror VX_tcu_core exactly.
    //   FEDP_LATENCY = VX_CFG_TCU_LATENCY           (VX_tcu_core.sv:51)
    //   PIPE_LATENCY = FEDP_LATENCY + 1             (:53)
    //   MDATA_QUEUE_DEPTH = 1 << clog2(PIPE_LATENCY)(:54)
    // -------------------------------------------------------------------------
    localparam FEDP_LATENCY     = `VX_CFG_TCU_LATENCY;
    localparam PIPE_LATENCY     = FEDP_LATENCY + 1;
    localparam TAG_QUEUE_DEPTH  = 1 << `CLOG2(PIPE_LATENCY);

    // Last K-step index per path. Loop order is K-outermost (VX_tcu_uops.sv),
    // so the final TCU_M_STEPS*TCU_N_STEPS uops of an instruction carry step_k
    // at its max, one per (m,n) sub-tile.
    localparam [3:0] K_LAST_NONWG = 4'(TCU_K_STEPS    - 1);
`ifdef VX_CFG_TCU_WGMMA_ENABLE
    localparam [3:0] K_LAST_WG    = 4'(TCU_WG_K_STEPS - 1);
`endif

    // -------------------------------------------------------------------------
    // Execute-side snoop — reconstruct VX_tcu_core's fedp_enqueue / is_setup.
    // -------------------------------------------------------------------------
    wire exe_fire = execute_if.valid && execute_if.ready;

`ifdef VX_CFG_TCU_WGMMA_ENABLE
    wire is_wgmma = (execute_if.data.op_type == INST_TCU_WGMMA)
              `ifdef VX_CFG_TCU_SPARSE_ENABLE
                 || (execute_if.data.op_type == INST_TCU_WGMMA_SP)
              `endif
                 ;
    // VX_tcu_core.sv:143 — is_wgmma_setup = is_wgmma && !header.wb
    wire is_setup = is_wgmma && ~execute_if.data.header.wb;
    wire [3:0] k_last = is_wgmma ? K_LAST_WG : K_LAST_NONWG;
`else
    wire is_wgmma = 1'b0;
    wire is_setup = 1'b0;
    wire [3:0] k_last = K_LAST_NONWG;
`endif

    wire [3:0] step_k     = execute_if.data.op_args.tcu.step_k;
    wire       tag_bit_in = (step_k == k_last);          // this uop is a sub-tile final

    // VX_tcu_core.sv:148 — fedp_enqueue = execute_fire && !is_wgmma_setup
    wire tag_push = exe_fire && ~is_setup;

    // -------------------------------------------------------------------------
    // Result-side snoop — reconstruct VX_tcu_core's setup_valid_r so we pop the
    // tag FIFO on exactly fedp_result_fire (VX_tcu_core.sv:204,206-218,267).
    // -------------------------------------------------------------------------
    wire res_fire = result_if.valid && result_if.ready;

    reg setup_valid_q;
    always @(posedge clk) begin
        if (reset) begin
            setup_valid_q <= 1'b0;
        end else begin
            if (res_fire && setup_valid_q) setup_valid_q <= 1'b0;  // setup_result_fire
            if (exe_fire && is_setup)      setup_valid_q <= 1'b1;   // setup_enqueue (wins)
        end
    end

    wire is_setup_beat = setup_valid_q;                  // current result beat is the setup beat
    wire tag_pop       = res_fire && ~is_setup_beat;     // == fedp_result_fire

    // -------------------------------------------------------------------------
    // Tag FIFO — same depth and OUT_REG as VX_tcu_core.mdata_queue so the tag
    // head tracks result_if.data.header 1:1.
    // -------------------------------------------------------------------------
    wire tag_q_out;
    wire tag_q_empty, tag_q_full;

    VX_fifo_queue #(
        .DATAW   (1),
        .DEPTH   (TAG_QUEUE_DEPTH),
        .OUT_REG (1)
    ) tag_queue (
        .clk      (clk),
        .reset    (reset),
        .push     (tag_push),
        .pop      (tag_pop),
        .data_in  (tag_bit_in),
        .data_out (tag_q_out),
        .empty    (tag_q_empty),
        `UNUSED_PIN (alm_empty),
        .full     (tag_q_full),
        `UNUSED_PIN (alm_full),
        `UNUSED_PIN (size)
    );

    // A setup beat carries no FEDP payload -> never tile-final; a genuine
    // compute beat is tile-final iff its queued tag is set.
    assign is_tile_final = res_fire ? (~is_setup_beat && ~tag_q_empty && tag_q_out)
                                    : 1'b0;

    // =========================================================================
    // Assertions (simulation only). Mirror gcb-spec/vortex_integration_notes.md
    // §8.4 A1..A5 at the module boundary.
    // =========================================================================
`ifdef SIMULATION
    // A3-support: a compute result beat must always have a tag queued.
    `RUNTIME_ASSERT (!(res_fire && ~is_setup_beat) || ~tag_q_empty,
        ("%s: compute result beat with empty tag FIFO — push/pop model diverged from VX_tcu_core", INSTANCE_ID))

    // FIFO overflow guard — TAG_QUEUE_DEPTH must equal MDATA_QUEUE_DEPTH.
    `RUNTIME_ASSERT (!(tag_push && tag_q_full && ~tag_pop),
        ("%s: tag FIFO overflow — TAG_QUEUE_DEPTH != VX_tcu_core MDATA_QUEUE_DEPTH", INSTANCE_ID))

    // A5 regression guard: header.eop must NOT be a proxy for tile-final.
    // (If a future Vortex rebase repurposes eop, this fires and forces review.)
`ifdef VX_TCU_TILEFINAL_EOP_GUARD
    reg  eop_matches_tf_seen;
    always @(posedge clk) begin
        if (reset) eop_matches_tf_seen <= 1'b0;
        else if (res_fire && ~is_setup_beat && (result_if.data.header.eop != is_tile_final))
            eop_matches_tf_seen <= 1'b1;    // at least one beat where they differ — good
    end
    // Expect eop_matches_tf_seen to be 1 by end-of-test for any multi-K config.
`endif

    // K_STEPS==1 degenerate note: every compute uop is tile-final; the marker
    // collapses to ~is_setup_beat. Valid, but flag it so the shim isn't
    // "filtering" nothing.
    initial begin
        if (K_LAST_NONWG == 4'd0)
            $display("[%s] NOTE: TCU_K_STEPS==1 — every non-setup result beat is tile-final.", INSTANCE_ID);
    end
`endif

endmodule
