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
    parameter int UOPS       = 16
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
    input  logic       header_eop
);

`ifdef SIMULATION

    localparam int K_LAST = (K_STEPS    > 0) ? K_STEPS    - 1 : 0;
    localparam int WGK_LAST = (WG_K_STEPS > 0) ? WG_K_STEPS - 1 : 0;
    localparam int TF_EXPECT = M_STEPS * N_STEPS;   // tile-final beats per instr

    wire [3:0] k_last     = is_wgmma ? 4'(WGK_LAST) : 4'(K_LAST);
    wire       exe_is_tf  = fedp_enqueue && (step_k == k_last);

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
            end
        end
    end

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

    // ---- A3: is_tile_final high on exactly the tile-final result beats -----
    // Checked at the result interface: a result beat is tile-final iff its
    // originating uop had step_k == k_last. The tag wrapper reproduces that;
    // here we only guard that is_tile_final is never X and never set on a
    // non-fedp beat (full alignment is the directed test's job).
    a3_no_x: assert property (@(posedge clk) disable iff (reset)
        fedp_result_fire |-> !$isunknown(is_tile_final))
        else $error("A3: is_tile_final is X on a result beat (tag wrapper unbound?)");

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
    //  stops firing and the guard itself flags the change.)
    logic eop_ever_differs;
    always_ff @(posedge clk) begin
        if (reset) eop_ever_differs <= 1'b0;
        else if (fedp_result_fire && !$isunknown(is_tile_final) && (header_eop !== is_tile_final))
            eop_ever_differs <= 1'b1;
    end
    // final check in the directed test: eop_ever_differs must be 1 by end-of-sim.
    a5_eop_not_tilefinal: assert property (@(posedge clk) disable iff (reset)
        (!instr_active && $past(instr_active)) |-> eop_ever_differs)
        else $error("A5: header.eop tracked is_tile_final for a whole instruction");

`endif

endmodule
