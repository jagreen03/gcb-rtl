// =============================================================================
// GreenCoyote-Bay — Ten-Four writeback -> Q17.14 shim (Vortex-side staging RTL)
// Project: ODIN_Bridge / Cascaded Optical Reduction Fabric
// =============================================================================
// Draft reference implementation of the compute-side shim specified in
//   gcb-spec/carry_save_streaming_contract.md  §4.1, §4.2, §6
//   gcb-spec/vortex_integration_notes.md        §5, §8
//
// Belongs in the VORTEX tree, not the pilot OOC build (build.tcl globs only
// rtl/*.sv and rtl/generated/*.sv). Tracked here under gcb-rtl/integration/ so
// it is reviewed alongside the contract.
//
// Function
// --------
// Consumes VX_tcu_core.result_if (via VX_tcu_tilefinal_tag, which supplies
// `is_tile_final` and `fmt_d` aligned to result_if.valid) and, for every
// tile-final result beat, converts each of NUM_LANES resolved 32-bit PE words
// to Q17.14 two's-complement and drives them out as NUM_LANES AXI4-Stream beats
// on one M_AXIS_CS master (one master per TCU block; the pilot demuxes the
// NUM_LANES beats into its per-lane FIFOs by TUSER.cell_lane, TLAST on the last).
//
//   float modes (fmt_d[4]==0): writeback word is IEEE-754 binary32.
//     q = rne( f32 * 2^14 ), saturating to the 32-bit signed range
//     (= Q17.14 full scale, contract §4.2). e==0 -> flush to 0.
//     e==255 (NaN/Inf) -> saturate + TUSER.nan_inf (pilot drops the reduction).
//   integer modes (fmt_d[4]==1): writeback word is int32.
//     q = sat32( rne( $signed(int32) <<< (14 - int_prescale) ) ).
//     int_prescale is the per-tensor requant right-shift; drive it from a CSR
//     so a large K-accumulated INT8 sum lands inside Q17.14 (contract §4.2,
//     §9 "Q17.14 range").
//
// Non-tile-final result beats are accepted (result_if.ready held) and dropped:
// the register file still receives every MMA writeback; only the fully-
// accumulated tile enters the optical reduction (contract §6.2).
//
// The pilot-side block-floating-point pass (contract §5) does the actual
// 32 -> 12 bit windowing; this shim only produces a faithful Q17.14 word plus
// the nan_inf / clamp flags.
//
// Draft notes:
//  * A tile-final beat holds result_if.ready low for NUM_LANES cycles while the
//    record serialises. Within the buffer-halt model (contract §6.4); revisit
//    if it eats too much FEDP-landing-queue slack at large NUM_LANES.
//  * Extreme negative saturation lands at -(2^31-1), one LSB short of Q_MIN,
//    except on the NaN/Inf/ovf path which writes Q_MIN directly. Harmless for
//    the BFP pass; tighten if a bit-exact bench correlation needs it.
//  * Lint/CI against the Vortex build flow (Verilator + iverilog) is pending —
//    expect nits on cross-branch unused temps and shift-amount signedness.
// =============================================================================

`include "VX_define.vh"

// Bit-exact conversion arithmetic lives in a dependency-free package so it is
// one source of truth with tb/tb_VX_tcu_q1714_convert.sv.
module VX_tcu_shim_q1714 import VX_gpu_pkg::*, VX_tcu_pkg::*,
                                 VX_tcu_q1714_convert_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",
    parameter NUM_LANES = TCU_TC_M * TCU_TC_N,   // PE words per result beat
    parameter TID_W     = 4,
    parameter SHIM_ROUND = "RNE"                 // "RNE" | "TRUNC" (bring-up)
) (
    input  wire                     clk,
    input  wire                     reset,

    // ---- from VX_tcu_tilefinal_tag --------------------------------------
    VX_result_if.slave              result_if,       // tcu_result_t
    input  wire                     is_tile_final,   // aligned to result_if.valid
    input  wire [4:0]               fmt_d,           // aligned to result_if.valid
    input  wire [5:0]               int_prescale,    // per-tensor requant shift (CSR)
    input  wire [TID_W-1:0]         cfg_tid,         // this block's stream id

    // ---- AXI4-Stream master: M_AXIS_CS (contract §6.1) -----------------
    output wire                     m_axis_tvalid,
    input  wire                     m_axis_tready,
    output wire [31:0]              m_axis_tdata,    // Q17.14
    output wire                     m_axis_tlast,    // last lane of the record
    output wire [TID_W-1:0]         m_axis_tid,
    output wire [5:0]               m_axis_tuser,    // {nan_inf, clamp_src, cell_lane[3:0]}
    output wire [3:0]               m_axis_tkeep
);
    `UNUSED_SPARAM (INSTANCE_ID)
    localparam LANE_W = `CLOG2(NUM_LANES);

    // TUSER.cell_lane is [3:0] (contract §6.1); a block with > 16 PE words needs
    // the thread-lane -> optical-lane map from vortex_integration_notes.md §9.
    `STATIC_ASSERT (NUM_LANES <= 16, ("NUM_LANES exceeds TUSER.cell_lane width"))

    // Conversion arithmetic (fp32/int32 -> Q17.14) is in the dependency-free
    // package VX_tcu_q1714_convert_pkg, shared bit-for-bit with
    // tb/tb_VX_tcu_q1714_convert.sv. round_trunc = floor instead of rne.
    localparam bit RND_TRUNC = (SHIM_ROUND == "TRUNC");

    // =========================================================================
    // Load FSM: on a tile-final result beat, latch the NUM_LANES words + fmt_d,
    // then push one converted lane per cycle into the egress FIFO.
    // =========================================================================
    wire is_int = fmt_d[4];   // tcu_fmt_is_int(): int formats set the top bit

    typedef enum logic [0:0] { S_IDLE, S_LOAD } state_e;
    state_e state;

    logic [NUM_LANES-1:0][31:0] lane_w_r;
    logic                       is_int_r;
    logic [5:0]                 presc_r;
    logic [LANE_W:0]            lane_ctr;    // 0 .. NUM_LANES

    wire egr_full;
    wire res_beat = result_if.valid;

    // accept a result beat only in IDLE and only if the FIFO can take a full
    // record (NUM_LANES entries) — simplest safe admission
    wire egr_room_for_record;
    wire can_load = (state == S_IDLE) && res_beat && egr_room_for_record;

    assign result_if.ready = (state == S_IDLE) && (~is_tile_final || egr_room_for_record);
    // non-tile-final beats: accepted and dropped (ready high, no load)

    wire [33:0] conv = conv_word(lane_w_r[lane_ctr[LANE_W-1:0]], is_int_r, presc_r, RND_TRUNC);
    wire        conv_nan = conv[33];
    wire        conv_ovf = conv[32];
    wire [31:0] conv_q   = conv[31:0];

    // egress word pack (MSB..LSB): tdata[31:0] | tlast | nan | ovf | cell_lane[3:0]
    localparam EGR_W = 32 + 1 + 1 + 1 + 4;   // = 39
    wire egr_push     = (state == S_LOAD);
    wire egr_tlast_in = (lane_ctr == (NUM_LANES-1));
    wire [EGR_W-1:0] egr_din =
        { conv_q, egr_tlast_in, conv_nan, conv_ovf, 4'(lane_ctr[LANE_W-1:0]) };

    always @(posedge clk) begin
        if (reset) begin
            state    <= S_IDLE;
            lane_ctr <= '0;
            is_int_r <= 1'b0;
            presc_r  <= '0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (can_load && is_tile_final) begin
                        for (int l = 0; l < NUM_LANES; l++)
                            lane_w_r[l] <= result_if.data.data[l][31:0];
                        is_int_r <= is_int;
                        presc_r  <= int_prescale;
                        lane_ctr <= '0;
                        state    <= S_LOAD;
                    end
                end
                S_LOAD: begin
                    // one push per cycle (egr FIFO sized so it never blocks a record)
                    if (lane_ctr == (NUM_LANES-1)) begin
                        lane_ctr <= '0;
                        state    <= S_IDLE;
                    end else begin
                        lane_ctr <= lane_ctr + 1'b1;
                    end
                end
            endcase
        end
    end

    // =========================================================================
    // Egress FIFO -> AXI4-Stream master
    // =========================================================================
    localparam EGR_DEPTH = 2 * (1 << `CLOG2(NUM_LANES));   // >= two full records

    wire [EGR_W-1:0] egr_dout;
    wire egr_empty;
    wire [`CLOG2(EGR_DEPTH+1)-1:0] egr_size;

    VX_fifo_queue #(
        .DATAW   (EGR_W),
        .DEPTH   (EGR_DEPTH),
        .OUT_REG (1)
    ) egress_fifo (
        .clk       (clk),
        .reset     (reset),
        .push      (egr_push),
        .pop       (m_axis_tvalid && m_axis_tready),
        .data_in   (egr_din),
        .data_out  (egr_dout),
        .empty     (egr_empty),
        `UNUSED_PIN (alm_empty),
        .full      (egr_full),
        `UNUSED_PIN (alm_full),
        .size      (egr_size)
    );

    assign egr_room_for_record = (egr_size <= (EGR_DEPTH - NUM_LANES));

    assign m_axis_tvalid = ~egr_empty;
    assign m_axis_tdata  = egr_dout[EGR_W-1 -: 32];   // [38:7]
    assign m_axis_tlast  = egr_dout[6];
    assign m_axis_tuser  = egr_dout[5:0];             // {nan_inf, clamp_src, cell_lane[3:0]}
    assign m_axis_tid    = cfg_tid;
    assign m_axis_tkeep  = 4'hF;

`ifdef SIMULATION
    `RUNTIME_ASSERT (!(egr_push && egr_full),
        ("%s: egress FIFO overflow — EGR_DEPTH too small for a record", INSTANCE_ID))
    // a tile-final beat must never be silently dropped
    `RUNTIME_ASSERT (!(state == S_IDLE && result_if.valid && is_tile_final
                       && result_if.ready == 1'b0 && egr_room_for_record),
        ("%s: tile-final beat not accepted despite FIFO room", INSTANCE_ID))
`endif

endmodule
