// =============================================================================
// GreenCoyote-Bay <-> Vortex 3.0 — tile-final marker SVA checker
// =============================================================================
// Implements vortex_integration_notes.md sec 8.4 assertions A1..A5 for the
// `step_k == BLOCK_K_STEPS-1` tile-final derivation. Intended to be `bind`-ed
// into VX_tcu_core so it sees the core's own predicates:
//
//   bind VX_tcu_core VX_tcu_tilefinal_sva #(
//       .M_STEPS (TCU_M_STEPS), .N_STEPS (TCU_N_STEPS),
//       .K_STEPS (TCU_K_STEPS), .WG_K_STEPS (TCU_WG_K_STEPS),
//       .UOPS    (TCU_UOPS)
//   ) u_tilefinal_sva (
//       .clk               (clk),
//       .reset             (reset),
//       .execute_fire      (execute_fire),
//       .fedp_enqueue      (fedp_enqueue),
//       .fedp_result_fire  (fedp_result_fire),
//       .is_wgmma          (is_wgmma),
//       .step_m            (step_m),
//       .step_n            (step_n),
//       .step_k            (step_k),
//       .is_tile_final     (/* from VX_tcu_tilefinal_tag, or 1'bx if unbound */),
//       .header_eop        (execute_if.data.header.eop)
//   );
//
// STATUS: draft — authored from the source cites in vortex_integration_notes.md
// sec 8; NOT yet elaborated (needs Verilator >= 5 + the vortex sibling clone;
// see integration/tb/run_tilefinal_check.sh). Reviewed-not-executed.
// =============================================================================

module VX_tcu_tilefinal_sva #(
    parameter int M_STEPS    = 4,
    parameter int N_STEPS    = 2,
    parameter int K_STEPS    = 2,
    parameter int WG_K_STEPS = 2,
    parameter int UOPS       = 16,
    parameter int TC_K       = 2,       // per-uop K depth (VX_tcu_pkg::TCU_TC_K)
    parameter int TILE_K     = 4,       // full tile K = TC_K * K_STEPS (TCU_TILE_K)
    parameter int NLANES     = 8        // VX_gpu_pkg::NUM_TCU_LANES (result lanes)
)(
    input  logic       clk,
    input  logic       reset,

    // VX_tcu_core execute-side predicates
    input  logic       execute_fire,       // execute_if.valid && execute_if.ready
    input  logic       fedp_enqueue,       // execute_fire && !is_wgmma_setup
    input  logic       fedp_result_fire,   // result beat leaving the FEDP path
    input  logic       is_wgmma,
    input  logic [3:0] step_m,
    input  logic [3:0] step_n,
    input  logic [3:0] step_k,

    // Marker under test (VX_tcu_tilefinal_tag.is_tile_final) and the eop it must
    // NOT track. Tie is_tile_final to 1'bx when the tag wrapper is not bound.
    input  logic       is_tile_final,
    input  logic       header_eop,

    // result_if.data.data — per-lane INT32/FP32 result words (numeric isolation)
    input  logic [NLANES-1:0][31:0] res_lane
);

`ifdef SIMULATION

    localparam int K_LAST = (K_STEPS    > 0) ? K_STEPS    - 1 : 0;
    localparam int WGK_LAST = (WG_K_STEPS > 0) ? WG_K_STEPS - 1 : 0;
    localparam int TF_EXPECT = M_STEPS * N_STEPS;   // tile-final beats per instr

    wire [3:0] k_last     = is_wgmma ? 4'(WGK_LAST) : 4'(K_LAST);
    wire       exe_is_tf  = fedp_enqueue && (step_k == k_last);

    // is_tile_final is driven when the VX_tcu_tilefinal_tag observer is bound
    // (run_tilefinal_check.sh stage 3); tied X otherwise, in which case A3/A5
    // are inert and A1/A2/A4 + the DPI counts carry the check.
    wire tag_present = !$isunknown(is_tile_final);

`ifdef GCB_TF_DPI
    // Directed-test instrumentation (run_tilefinal_check.sh stage 3). kind:
    //   0 = params        (a=UOPS, b=TF_EXPECT, c=TILE_K)
    //   1 = enqueue       (a=step_k, b=k_last)
    //   2 = result        (a=beats_out+1, b=is_tile_final on this result beat)
    //   3 = retire        (a=beats_in, b=tf_in, c=tf_result_beats)
    //   4 = tag went live (a=1)
    import "DPI-C" function void gcb_tf_event(input int kind, input int a,
                                              input int b, input int c);
    initial gcb_tf_event(0, UOPS, TF_EXPECT, TILE_K);
`endif

    // ---- reference is_tile_final: mirror FIFO of (step_k == k_last) ----------
    // Push on fedp_enqueue, pop on fedp_result_fire. The head is the expected
    // tile-final flag for the current result beat — cross-checked against the
    // VX_tcu_tilefinal_tag observer's is_tile_final in A3.
    localparam int REFD = 128;   // >> any TCU FEDP latency
    logic         ref_mem [REFD];
    int unsigned  ref_wr, ref_rd;
    wire          ref_empty = (ref_wr == ref_rd);
    wire          tf_ref    = ref_empty ? 1'b0 : ref_mem[ref_rd % REFD];

    always_ff @(posedge clk) begin
        if (reset) begin
            ref_wr <= 0; ref_rd <= 0;
        end else begin
            if (fedp_enqueue)     begin ref_mem[ref_wr % REFD] <= (step_k == k_last); ref_wr <= ref_wr + 1; end
            if (fedp_result_fire) ref_rd <= ref_rd + 1;
        end
    end

    // ---- tile-final RESULT-beat count (the M_AXIS_CS tap) -------------------
    int unsigned tf_result_beats;
    always_ff @(posedge clk) begin
        if (reset)                              tf_result_beats <= 0;
        else if (fedp_enqueue && !instr_active) tf_result_beats <= (fedp_result_fire && tf_ref) ? 1 : 0;
        else if (fedp_result_fire && tf_ref)    tf_result_beats <= tf_result_beats + 1;
    end

    // ---- per-instruction counters -------------------------------------------
    // A new instruction = the first fedp_enqueue after all outstanding result
    // beats have drained (beats_out has caught up to beats_in).
    int unsigned beats_in;      // fedp_enqueue count, current instruction
    int unsigned beats_out;     // fedp_result_fire count, current instruction
    int unsigned tf_in;         // exe_is_tf count, current instruction
    logic        instr_active;

    always_ff @(posedge clk) begin
        if (reset) begin
            beats_in <= 0; beats_out <= 0; tf_in <= 0; instr_active <= 1'b0;
        end else begin
            // start of a new instruction
            if (fedp_enqueue && !instr_active) begin
                beats_in     <= 1;
                tf_in        <= exe_is_tf ? 1 : 0;
                beats_out    <= 0;
                instr_active <= 1'b1;
            end else begin
                if (fedp_enqueue)     beats_in <= beats_in + 1;
                if (fedp_enqueue && exe_is_tf) tf_in <= tf_in + 1;
                if (fedp_result_fire) beats_out <= beats_out + 1;
            end
            // instruction retires when the last expected result beat leaves
            if (instr_active && (beats_in == UOPS) &&
                (beats_out + (fedp_result_fire ? 1 : 0) == UOPS)) begin
                instr_active <= 1'b0;
`ifdef GCB_TF_DPI
                gcb_tf_event(3, int'(beats_in), int'(tf_in),
                             int'(tf_result_beats + ((fedp_result_fire && tf_ref) ? 1 : 0)));
`endif
            end
`ifdef GCB_TF_DPI
            if (fedp_enqueue)     gcb_tf_event(1, int'(step_k), int'(k_last), 0);
            if (fedp_result_fire) gcb_tf_event(2, int'(beats_out + 1), int'(is_tile_final), 0);
            if (tag_present && !tag_present_q) gcb_tf_event(4, 1, 0, 0);
`endif
        end
    end

`ifdef GCB_TF_DPI
    logic tag_present_q;
    always_ff @(posedge clk) tag_present_q <= reset ? 1'b0 : (tag_present_q | tag_present);
`endif

    // ---- A1: exactly UOPS execute enqueues per instruction -----------------
    a1_uop_count: assert property (@(posedge clk) disable iff (reset)
        (instr_active && beats_in == UOPS) |-> (beats_in == UOPS))
        else $error("A1: instruction issued %0d uops, expected %0d", beats_in, UOPS);

    a1_result_count: assert property (@(posedge clk) disable iff (reset)
        (!instr_active && $past(instr_active)) |-> ($past(beats_out) + 1 == UOPS || $past(beats_out) == UOPS))
        else $error("A1: instruction produced != %0d result beats", UOPS);

    // ---- A2: exactly M_STEPS*N_STEPS beats carry step_k == K_STEPS-1 -------
    a2_tf_count: assert property (@(posedge clk) disable iff (reset)
        (!instr_active && $past(instr_active)) |-> ($past(tf_in) == TF_EXPECT))
        else $error("A2: %0d tile-final uops, expected %0d", $past(tf_in), TF_EXPECT);

    // ---- A3: is_tile_final on a compute result beat == (that beat's uop had
    //         step_k == k_last). The VX_tcu_tilefinal_tag observer's marker is
    //         cross-checked against the SVA's own mirror-FIFO reference tf_ref.
    a3_no_x: assert property (@(posedge clk) disable iff (reset || !tag_present)
        fedp_result_fire |-> !$isunknown(is_tile_final))
        else $error("A3: is_tile_final is X on a compute result beat");

    a3_align: assert property (@(posedge clk) disable iff (reset || !tag_present)
        fedp_result_fire |-> (is_tile_final === tf_ref))
        else $error("A3: tag is_tile_final=%b != reference tf_ref=%b on result beat %0d",
                    is_tile_final, tf_ref, beats_out);

    // ---- A4: the step_k==last beat is the final writeback for its (m,n) -----
    // Loop order is K-outermost, so once step_k hits k_last it stays k_last for
    // the rest of the instruction. Assert monotonicity of step_k within an
    // instruction (never returns to < k_last after reaching it).
    logic seen_klast;
    always_ff @(posedge clk) begin
        if (reset || (fedp_enqueue && !instr_active)) seen_klast <= (fedp_enqueue && (step_k == k_last));
        else if (fedp_enqueue)                        seen_klast <= seen_klast | (step_k == k_last);
    end
    a4_k_monotone: assert property (@(posedge clk) disable iff (reset)
        (instr_active && fedp_enqueue && seen_klast) |-> (step_k == k_last))
        else $error("A4: step_k returned to %0d after reaching k_last %0d", step_k, k_last);

    // ---- A5: header.eop must NOT equal is_tile_final on every beat ---------
    // (regression guard — if a future rebase repurposes eop as tile-final this
    //  stops firing and the guard itself flags the change.) Needs the tag
    //  wrapper; inert when is_tile_final is tied X.
    logic eop_ever_differs;
    always_ff @(posedge clk) begin
        if (reset) eop_ever_differs <= 1'b0;
        else if (fedp_result_fire && tag_present && (header_eop !== is_tile_final))
            eop_ever_differs <= 1'b1;
    end
    a5_eop_not_tilefinal: assert property (@(posedge clk) disable iff (reset || !tag_present)
        (!instr_active && $past(instr_active)) |-> eop_ever_differs)
        else $error("A5: header.eop tracked is_tile_final for a whole instruction");

    // =====================================================================
    // Numeric isolation — INT8 WMMA INT32 accumulator lanes (GCB_TF_NUMISO,
    // set by run_tilefinal_check.sh only for INT8 configs). Directed stimulus:
    // A = B = all-ones INT8, C = 0, so one FEDP execute beat reduces the whole
    // per-config tile-K: every compute result lane holds the same value D_ref,
    // observed to be 8 (NUM_THREADS=8) or 16 (NUM_THREADS=16) -- the "TILE_K =
    // 8 or 16" of vortex_integration_notes.md sec 8.4. |D| max for INT8*INT8
    // over K<=16 is 127*127*16 = 258064 < 2**18, so bits [31:20] of a
    // non-overflowed lane are zero and the value is non-negative.
    // =====================================================================
`ifdef GCB_TF_NUMISO
    // non-WGMMA: fedp_result_fire already excludes WGMMA setup beats
    wire compute_res_beat = fedp_result_fire;

    // D_ref: latch lane 0 of the first compute result beat; every later lane /
    // beat must match it (self-consistent -- no hard-coded constant, since the
    // effective tile-K scales with NUM_THREADS).
    logic [31:0] d_ref;
    logic        d_ref_set;
    always_ff @(posedge clk) begin
        if (reset) d_ref_set <= 1'b0;
        else if (compute_res_beat && !d_ref_set) begin
            d_ref     <= res_lane[0];
            d_ref_set <= 1'b1;
        end
    end

    // D_ref must be one of the two legal effective tile-K depths.
    n0_tilek_legal: assert property (@(posedge clk) disable iff (reset)
        (compute_res_beat && !d_ref_set) |->
            ($signed(res_lane[0]) == 8 || $signed(res_lane[0]) == 16))
        else $error("N0: effective TILE_K = %0d, expected 8 or 16", $signed(res_lane[0]));

    for (genvar gl = 0; gl < NLANES; gl++) begin : g_numiso
        // N1 -- no INT32 overflow / no high-bit bleed from an adjacent lane.
        n1_no_overflow: assert property (@(posedge clk) disable iff (reset)
            compute_res_beat |->
                ($signed(res_lane[gl]) >= 0 && res_lane[gl][31:20] == 12'd0))
            else $error("N1: lane %0d INT32 overflow / high-bit bleed: 0x%08x",
                        gl, res_lane[gl]);

        // N2 -- no cross-lane bleed: all-ones operands => every lane identical.
        n2_no_lane_bleed: assert property (@(posedge clk) disable iff (reset)
            compute_res_beat |-> (res_lane[gl] == res_lane[0]))
            else $error("N2: lane %0d = 0x%08x != lane 0 = 0x%08x (cross-lane bleed)",
                        gl, res_lane[gl], res_lane[0]);

        // N3 -- stable: every compute result lane == the latched D_ref.
        n3_stable: assert property (@(posedge clk) disable iff (reset || !d_ref_set)
            compute_res_beat |-> (res_lane[gl] == d_ref))
            else $error("N3: lane %0d = %0d drifts from D_ref = %0d",
                        gl, $signed(res_lane[gl]), $signed(d_ref));
    end

`ifdef GCB_TF_DPI
    // kind 5 = first compute result beat's lane-0 value (a=value, b=NLANES)
    logic numiso_reported;
    always_ff @(posedge clk) begin
        if (reset) numiso_reported <= 1'b0;
        else if (compute_res_beat && !numiso_reported) begin
            numiso_reported <= 1'b1;
            gcb_tf_event(5, int'($signed(res_lane[0])), NLANES, 0);
        end
    end
`endif
`endif

`endif

endmodule
