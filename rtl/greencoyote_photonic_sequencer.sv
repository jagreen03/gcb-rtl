// =============================================================================
// GreenCoyote-Bay — Photonic Sequencer
// Project: ODIN_Bridge / Cascaded Optical Reduction Fabric
// Author:  John A. Green
// Date:    June 2026
// =============================================================================
// Orchestrates the 8-channel optical reduction pipeline.
// Handles gain trim normalization, precision packing, DAC fire strobe,
// ADC capture, and 2-pass cascaded reduction for 14-GPU workloads.
//
// State Machine:
//   IDLE → NORMALIZE → FIRE → CAPTURE → PASS_CHECK → LOAD_PASS2 → CAPTURE2 → DONE
//
// NORMALIZE runs the block-floating-point (BFP) pass of
// carry_save_streaming_contract.md sec 5.1-5.3 as a BFP_LAT-stage synchronous
// PIPELINE (see the "BFP NORMALIZE pipeline" block below): derive a shared
// block exponent from the active-lane magnitudes, arithmetic-shift each 32-bit
// Q17.14 accumulator word into the 12-bit DAC window, round per ROUND_MODE,
// add the offset-binary lane bias, clamp, and precision-pack. All of the
// pipeline's inputs are frozen for the reduction, so NORMALIZE just dwells for
// the pipe to fill and then latches the time-aligned final stage in one cycle
// (the old separate PACK state is folded into that latch). The shared exponent
// and the active lane count are held for the post-ADC reconstruction in
// CAPTURE/CAPTURE2 (sec 5.4). This replaced the earlier `buf_data[i][11:0]`
// static truncation; the pipeline replaced an ~88-level combinational path
// (WNS -15.877 ns @ 300 MHz, Vivado DPIP-2 / DPOP-3 / DPOP-4).
// =============================================================================

module greencoyote_photonic_sequencer #(
    // Streaming Tensor DMA operand feed — optical-array geometry
    // (gcb-spec/docs/optical_geometry_spec.md v1.0.0, LOCKED).
    parameter int DMA_OPT_N        = 64,     // parallel optical channels
    parameter int DMA_OPT_L        = 16,     // contraction lanes per channel per fire
    parameter int DMA_OPT_BITS     = 8,      // INT8 operand
    parameter int DMA_FIRES_PER_WIN= 512,    // optical beats per 256 ns accumulation window
    parameter int DMA_ACT_W        = DMA_OPT_L*DMA_OPT_BITS,          // 128
    parameter int DMA_WT_W         = DMA_OPT_N*DMA_OPT_L*DMA_OPT_BITS // 8192
)(
    input  logic        clk,
    input  logic        rst_n,

    // --- Register Block Interface ---
    input  logic        fire,                   // Trigger pulse from reg block
    input  logic        auto_fire,              // Autonomous mode
    input  logic [2:0]  mode_sel,               // 000=INT4 001=FP4 010=FP8 011=BF16
    input  logic [1:0]  sat_guard,              // Guard bits for clipping
    input  logic [1:0]  noise_headroom,         // Reserved noise bits
    input  logic [1:0]  round_mode,             // REDUCTION_CTRL.ROUND_MODE — BFP rounding (sec 5.2)
    input  logic [11:0] dark_offset,            // Photodetector dark current
    input  logic [7:0]  trim_ch [0:7],          // Per-channel gain coefficients

    output logic        mode_active,            // Reduction in progress
    output logic [1:0]  pass_index,             // 00=Pass1a 01=Pass1b 10=Pass2
    output logic [3:0]  queue_depth,            // Channels with data ready
    output logic        cal_err,                // ADC clip or integrity fault
    output logic        fire_done,              // Reduction complete pulse
    output logic        queue_full,             // All active channels ready

    // --- BFP scale status (to pilot_regs BLK_SCALE_STATUS 0xAC) ---
    output logic [4:0]  blk_exp_last,           // Shared block exponent, last fire (sec 5.1)
    output logic        blk_scale_clamp,        // Sticky: a lane clamped in the BFP window (sec 5.1/sec 7)
    output logic [3:0]  lane_bias_n,            // Active lane count latched at fire (sec 5.3 de-bias)

    // --- Reconstructed partial sum — cascade stage / fabric output (contract sec 8.3) ---
    output logic signed [31:0] stage_result,    // (adc - n*2048) <<< blk_exp, Q17.14 (sec 5.4)
    output logic        stage_result_valid,     // 1-cycle strobe at reduction completion

    // --- Buffer Interface (from GPU partial sum buffers) ---
    input  logic [31:0] buf_data [0:7],         // Partial sum per GPU channel
    input  logic [7:0]  buf_full,               // Per-channel ready flags
    output logic [7:0]  buf_clear,              // Clear flags after read

    // --- DAC PHY Interface ---
    output logic [11:0] dac_data [0:7],         // 12-bit DAC values post trim
    output logic [7:0]  dac_valid,              // Per-channel DAC load enable
    output logic        dac_sync,               // Simultaneous fire strobe

    // --- ADC PHY Interface ---
    input  logic [11:0] adc_data,               // 12-bit ADC result
    input  logic        adc_valid,              // ADC conversion complete
    input  logic        conv_fault,             // ADC conversion fault (1-cycle, with adc_valid)

    // -------------------------------------------------------------------------
    // Streaming Tensor DMA operand feed — optical (T_fire) clock domain.
    // Separate from the carry-save reduction datapath above: this is the
    // Phase-II optical-multiply beat. The sequencer STALLS optical beat
    // generation until dma_armed is high (>= WINDOW_W operand rows buffered +
    // weight tile loaded), and asserts seq_fire for one opt_clk per consumed
    // operand row. greencoyote_streaming_dma sec 4.1; optical_geometry_spec.
    // -------------------------------------------------------------------------
    input  logic                    opt_clk,
    input  logic                    opt_rst_n,
    input  logic                    dma_armed,          // DMA feed ready for the window
    input  logic                    dma_operand_valid,  // act_data/wt_data valid this beat
    input  logic [DMA_ACT_W-1:0]    act_data,           // L x INT8 activation row (broadcast to all N)
    input  logic [DMA_WT_W-1:0]     wt_data,            // N x (L x INT8) weight operands
    output logic                    seq_fire,           // 1-cycle per consumed optical beat
    output logic                    opt_window_done     // 1-cycle at FIRES_PER_WIN boundary
);

// =============================================================================
// Parameters
// =============================================================================

localparam NUM_CH       = 8;
localparam NUM_CH_PASS2 = 6;    // 14-GPU: Pass1a=8, Pass1b=6 (zero-padded to 8)

// Precision mode encoding
localparam MODE_INT4 = 3'b000;
localparam MODE_FP4  = 3'b001;
localparam MODE_FP8  = 3'b010;
localparam MODE_BF16 = 3'b011;

// ADC clip detection threshold — top of SAT_GUARD window
localparam ADC_MAX   = 12'hFFF;
localparam ADC_CLIP_THRESH = 12'hF00;   // Flag if within top 256 counts

// BFP rounding modes — carry_save_streaming_contract.md sec 5.2
localparam ROUND_TRUNC = 2'b00;   // arithmetic shift only (floor toward -inf)
localparam ROUND_RNE   = 2'b01;   // round-nearest-even (reset default)
localparam ROUND_STOCH = 2'b10;   // stochastic, per-lane LFSR dither
                                  // 2'b11 reserved -> treated as truncate

// 12-bit DAC window: offset-binary zero and full-scale (sec 5.3)
localparam int OFFSET_BIN   = 2048;    // per active lane: code 0 -> value -2048
localparam int DAC_CODE_MAX = 4095;

// Per-lane stochastic-rounding LFSR — same polynomial as greencoyote_dac_if.sv
// (x^16 + x^15 + x^13 + x^4 + 1), one generator per optical lane, distinct seed.
localparam logic [15:0] LFSR_SEED0 = 16'hACE1;

// =============================================================================
// State machine definition
// =============================================================================

typedef enum logic [3:0] {
    IDLE        = 4'h0,
    NORMALIZE   = 4'h1,    // Dwell for the BFP pipeline; latch dac_data/blk_exp/clamp
    PACK        = 4'h2,    // (reserved — folded into the NORMALIZE latch)
    FIRE        = 4'h3,    // Assert dac_sync — optical summation
    CAPTURE     = 4'h4,    // Wait for adc_valid
    PASS_CHECK  = 4'h5,    // Determine if second pass needed
    LOAD_PASS2  = 4'h6,    // Load Pass 2 inputs (Stage 1a + 1b results)
    FIRE_PASS2  = 4'h7,    // Assert dac_sync for Pass 2
    CAPTURE2    = 4'h8,    // Wait for Pass 2 ADC result
    DONE        = 4'h9     // Assert fire_done, clear buffers
} seq_state_t;

seq_state_t state;

// =============================================================================
// Internal registers
// =============================================================================

logic [11:0] pass1a_result;         // Raw ADC result from Pass 1a
logic [11:0] pass1b_result;         // Raw ADC result from Pass 1b
logic [12:0] pass2_sum;             // Digital sum of raw Pass 1a + 1b (13-bit)
logic        is_14gpu_mode;         // Set when buf_full[5:0] all set — 14 GPU

// --- BFP outputs latched at the end of NORMALIZE, consumed later -------------
logic [4:0]  blk_exp_r;             // shared block exponent for the in-flight fire
logic [3:0]  lane_bias_n_r;         // active lane count (= queue_depth) at fire
logic [3:0]  bfp_dwell;             // NORMALIZE dwell counter — waits out the BFP pipe
// stage_result (sec 5.4 reconstruction) is a module output port.
logic signed [17:0] adc_debiased;  // adc_data_sync - lane_bias_n_r*2048 (pre-shift)

// --- Per-lane stochastic-rounding dither ------------------------------------
logic [15:0] lfsr [0:7];

// =============================================================================
// ADC clock-domain-crossing synchronizers
// -----------------------------------------------------------------------------
// adc_data / adc_valid arrive asynchronous to clk (they are driven from the
// ADC conversion clock). Bring the valid strobe across with a 2-flop
// synchronizer and pipe the data the same depth so it has settled by the time
// adc_valid_sync is observed. adc_data must be held stable by the ADC for the
// duration of adc_valid (standard data/valid handshake) for adc_data_sync to
// be coherent. The XDC cuts the async arc into the *_sync_meta stage.
// =============================================================================

(* ASYNC_REG = "TRUE" *) logic        adc_valid_sync_meta, adc_valid_sync;
(* ASYNC_REG = "TRUE" *) logic [11:0] adc_data_sync_meta,  adc_data_sync;
(* ASYNC_REG = "TRUE" *) logic        conv_fault_sync_meta, conv_fault_sync;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        adc_valid_sync_meta  <= 1'b0;
        adc_valid_sync       <= 1'b0;
        adc_data_sync_meta   <= 12'h000;
        adc_data_sync        <= 12'h000;
        conv_fault_sync_meta <= 1'b0;
        conv_fault_sync      <= 1'b0;
    end else begin
        adc_valid_sync_meta  <= adc_valid;
        adc_valid_sync       <= adc_valid_sync_meta;
        adc_data_sync_meta   <= adc_data;
        adc_data_sync        <= adc_data_sync_meta;
        conv_fault_sync_meta <= conv_fault;
        conv_fault_sync      <= conv_fault_sync_meta;
    end
end

// =============================================================================
// Queue depth and queue full logic
// =============================================================================

always_comb begin
    queue_depth = buf_full[0] + buf_full[1] + buf_full[2] + buf_full[3] +
                  buf_full[4] + buf_full[5] + buf_full[6] + buf_full[7];
    queue_full  = (buf_full == 8'hFF);          // All 8 channels full
    is_14gpu_mode = (buf_full[7:6] == 2'b00) && // Ch 6,7 empty
                    (buf_full[5:0] == 6'h3F);    // Ch 0-5 full — 6 GPU second pass
end

// =============================================================================
// BFP NORMALIZE pipeline  (carry_save_streaming_contract.md sec 5.1-5.3, 4.3)
// -----------------------------------------------------------------------------
// This was one ~88-level combinational cloud: buf_data -> an UNpipelined 32x9
// DSP multiply -> an 8-way magnitude max + 32-bit priority encoder -> a 32-bit
// arithmetic barrel shifter -> a 34-bit adder, terminating at dac_data_reg /
// blk_scale_clamp_reg / cal_err_reg. WNS -15.877 ns @ 300 MHz; Vivado
// DPIP-2 / DPOP-3 / DPOP-4 on the DSP48E2 instances.
//
// It is now a BFP_LAT-stage synchronous pipeline. Every input it consumes --
// buf_data, buf_full, trim_ch, mode_sel, sat_guard, noise_headroom, round_mode
// -- is held stable by greencoyote_pilot_regs / the per-lane FIFOs for the
// entire reduction: the lane FIFOs are not popped until DONE (buf_clear), and
// the config fields do not change mid-fire. The pipeline is therefore a plain
// fixed-latency shift of ONE stable operand set; after BFP_LAT stable clocks
// its final stage carries the correct result for this fire, and -- because
// every stage derives from the same frozen inputs -- all stage-N registers are
// mutually time-aligned. The FSM simply dwells BFP_LAT+ cycles in NORMALIZE
// and then latches the aligned final-stage outputs (be_p9, dac_packed_p9,
// clamp_p9) in a single cycle. The old PACK state is folded into that latch.
//
// DSP48E2 register mapping (stages P1..P3):
//   P1  bd_p1[i] / tr_p1[i]        -> DSP AREG, BREG   (resolves DPIP-2)
//   P2  prod_p2[i] = A * B         -> DSP MREG         (resolves DPOP-3)
//   P3  acc_p3[i] = prod_p2 >>> 8  -> DSP PREG         (resolves DPOP-4)
// The >>> 8 (Q41 -> Q17.14) is a constant bit-select on the PREG output. No
// C-port operand is routed into these DSPs, so CREG is not required. The
// downstream 34-bit bias/round adder (P8) is left in fabric CARRY8, out of the
// DSP, so it does not re-introduce a DSP post-adder without CREG.
// =============================================================================

localparam int BFP_LAT   = 9;            // pipeline depth: buf_data -> dac_packed
localparam int BFP_DWELL = BFP_LAT + 1;  // NORMALIZE dwell (one clock of margin)

function automatic logic [5:0] msb_index (input logic [31:0] v);
    msb_index = 6'd0;
    for (int b = 0; b < 32; b++)
        if (v[b]) msb_index = b[5:0];
endfunction

function automatic logic [31:0] abs32 (input logic signed [31:0] v,
                                       input logic active);
    abs32 = !active ? 32'd0 : (v[31] ? (~v + 32'd1) : v);
endfunction

function automatic logic [31:0] max32 (input logic [31:0] a, input logic [31:0] b);
    max32 = (a >= b) ? a : b;
endfunction

function automatic logic [4:0] blk_exp_of (input logic [5:0] msb,
                                           input logic [1:0] sg,
                                           input logic [1:0] nh);
    int win, br;
    win = 11 - int'(sg) - int'(nh);           // window position, [7..11]
    br  = int'(msb) - win;
    blk_exp_of = (br <= 0) ? 5'd0 : (br >= 31) ? 5'd31 : 5'(br);
endfunction

// {clamp, 12-bit offset-binary DAC code} for one lane (sec 5.2 / 5.3).
function automatic logic [12:0] bfp_pack (input logic               active,
                                          input logic [4:0]         be,
                                          input logic signed [32:0] shifted,
                                          input logic [31:0]        frac,
                                          input logic [31:0]        fmask,
                                          input logic [15:0]        lf,
                                          input logic [1:0]         rmode);
    logic               guard, sticky, rup;
    logic signed [33:0] biased;
    logic [12:0]        r;
    r = 13'd0;
    if (active) begin
        guard  = (be == 5'd0) ? 1'b0 : frac[be - 5'd1];
        sticky = (be <= 5'd1) ? 1'b0 : |(frac & (fmask >> 1));
        unique case (rmode)
            ROUND_RNE:   rup = guard & (sticky | shifted[0]);
            ROUND_STOCH: rup = (({16'd0, lf} & fmask) < frac);
            default:     rup = 1'b0;                      // TRUNC and 2'b11
        endcase
        biased = 34'($signed(shifted)) + $signed(34'(rup))
               + $signed(34'(OFFSET_BIN));
        if      (biased < 0)            r = {1'b1, 12'h000};
        else if (biased > DAC_CODE_MAX) r = {1'b1, 12'hFFF};
        else                            r = {1'b0, biased[11:0]};
    end
    bfp_pack = r;
endfunction

// ---- pipeline registers -------------------------------------------------
logic [31:0]         bd_p1  [0:7];   // P1  DSP AREG
logic [8:0]          tr_p1  [0:7];   // P1  DSP BREG
logic [7:0]          full_p1;
(* use_dsp = "yes" *) logic signed [40:0] prod_p2 [0:7];   // P2  DSP MREG
logic [7:0]          full_p2;
logic signed [31:0]  acc_p3 [0:7];   // P3  DSP PREG (>>> 8 applied)
logic [7:0]          full_p3;
logic [31:0]         pm_p4  [0:3];   // P4  pairwise |acc| max, 8 -> 4
logic signed [31:0]  acc_p4 [0:7];
logic [7:0]          full_p4;
logic [5:0]          blk_msb_p5;     // P5  msb_index(max), 0..32
logic signed [31:0]  acc_p5 [0:7];
logic [7:0]          full_p5;
logic [4:0]          be_p6;          // P6  shared block exponent
logic signed [31:0]  acc_p6 [0:7];
logic [7:0]          full_p6;
logic [15:0]         lfsr_p6 [0:7];  // dither sampled aligned with the lanes
logic signed [32:0]  shifted_p7 [0:7];   // P7  acc >>> be
logic [31:0]         frac_p7    [0:7];   //     discarded low bits
logic [31:0]         frac_mask_p7;
logic [4:0]          be_p7;
logic [7:0]          full_p7;
logic [15:0]         lfsr_p7 [0:7];
logic [12:0]         cw_p8 [0:7];    // P8  {clamp, 12-bit code} per lane
logic [4:0]          be_p8;
logic [7:0]          full_p8;
logic [11:0]         dac_packed_p9 [0:7];   // P9  precision-packed DAC word
logic [4:0]          be_p9;
logic                clamp_p9;
logic [7:0]          full_p9;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        full_p1 <= '0; full_p2 <= '0; full_p3 <= '0; full_p4 <= '0; full_p5 <= '0;
        full_p6 <= '0; full_p7 <= '0; full_p8 <= '0; full_p9 <= '0;
        blk_msb_p5 <= '0; be_p6 <= '0; be_p7 <= '0; be_p8 <= '0; be_p9 <= '0;
        frac_mask_p7 <= '0; clamp_p9 <= 1'b0;
        for (int i = 0; i < NUM_CH; i++) begin
            bd_p1[i] <= '0; tr_p1[i] <= '0; prod_p2[i] <= '0;
            acc_p3[i] <= '0; acc_p4[i] <= '0; acc_p5[i] <= '0; acc_p6[i] <= '0;
            shifted_p7[i] <= '0; frac_p7[i] <= '0;
            lfsr_p6[i] <= '0; lfsr_p7[i] <= '0;
            cw_p8[i] <= '0; dac_packed_p9[i] <= '0;
        end
        for (int j = 0; j < 4; j++) pm_p4[j] <= '0;
    end else begin
        // P1 : DSP input registers (AREG / BREG)
        full_p1 <= buf_full;
        for (int i = 0; i < NUM_CH; i++) begin
            bd_p1[i] <= buf_data[i];
            tr_p1[i] <= {1'b0, trim_ch[i]};                 // 9b unsigned
        end
        // P2 : DSP multiplier register (MREG) -- 32b signed * 9b unsigned in 41b
        full_p2 <= full_p1;
        for (int i = 0; i < NUM_CH; i++)
            prod_p2[i] <= $signed(bd_p1[i]) * $signed(tr_p1[i]);
        // P3 : DSP output register (PREG) + constant >>> 8 back to Q17.14
        full_p3 <= full_p2;
        for (int i = 0; i < NUM_CH; i++)
            acc_p3[i] <= 32'($signed(prod_p2[i]) >>> 8);
        // P4 : per-lane magnitude (inactive -> 0) + pairwise max, 8 -> 4
        full_p4 <= full_p3;
        for (int i = 0; i < NUM_CH; i++) acc_p4[i] <= acc_p3[i];
        for (int j = 0; j < 4; j++)
            pm_p4[j] <= max32(abs32(acc_p3[2*j],   full_p3[2*j]),
                              abs32(acc_p3[2*j+1], full_p3[2*j+1]));
        // P5 : max 4 -> 1  +  32-bit priority encoder
        full_p5 <= full_p4;
        for (int i = 0; i < NUM_CH; i++) acc_p5[i] <= acc_p4[i];
        blk_msb_p5 <= msb_index(max32(max32(pm_p4[0], pm_p4[1]),
                                      max32(pm_p4[2], pm_p4[3])));
        // P6 : shared block exponent (sec 5.1 step 2)  +  dither snapshot
        full_p6 <= full_p5;
        be_p6   <= blk_exp_of(blk_msb_p5, sat_guard, noise_headroom);
        for (int i = 0; i < NUM_CH; i++) begin
            acc_p6[i]  <= acc_p5[i];
            lfsr_p6[i] <= lfsr[i];
        end
        // P7 : arithmetic barrel shift  +  discarded-fraction extract
        full_p7      <= full_p6;
        be_p7        <= be_p6;
        frac_mask_p7 <= (be_p6 == 5'd0) ? 32'd0 : ((32'd1 << be_p6) - 32'd1);
        for (int i = 0; i < NUM_CH; i++) begin
            shifted_p7[i] <= $signed(acc_p6[i]) >>> be_p6;
            frac_p7[i]    <= acc_p6[i] & ((be_p6 == 5'd0) ? 32'd0
                                         : ((32'd1 << be_p6) - 32'd1));
            lfsr_p7[i]    <= lfsr_p6[i];
        end
        // P8 : round (sec 5.2) + offset-binary bias (sec 5.3) + [0,4095] clamp
        full_p8 <= full_p7;
        be_p8   <= be_p7;
        for (int i = 0; i < NUM_CH; i++)
            cw_p8[i] <= bfp_pack(full_p7[i], be_p7, shifted_p7[i],
                                 frac_p7[i], frac_mask_p7, lfsr_p7[i], round_mode);
        // P9 : precision packing by MODE_SEL (contract sec 4.3) -- final stage
        full_p9  <= full_p8;
        be_p9    <= be_p8;
        clamp_p9 <= cw_p8[0][12] | cw_p8[1][12] | cw_p8[2][12] | cw_p8[3][12]
                  | cw_p8[4][12] | cw_p8[5][12] | cw_p8[6][12] | cw_p8[7][12];
        for (int i = 0; i < NUM_CH; i++) begin
            if (!full_p8[i]) begin
                dac_packed_p9[i] <= 12'h000;               // zero-pad inactive
            end else begin
                case (mode_sel)
                    MODE_INT4: dac_packed_p9[i] <= {8'h00, cw_p8[i][3:0]};
                    MODE_FP4:  dac_packed_p9[i] <= {6'h00, cw_p8[i][5:0]};
                    MODE_FP8:  dac_packed_p9[i] <= cw_p8[i][11:0];
                    MODE_BF16: dac_packed_p9[i] <= cw_p8[i][11:0];
                    default:   dac_packed_p9[i] <= cw_p8[i][11:0];
                endcase
            end
        end
    end
end

// =============================================================================
// Per-lane stochastic-rounding LFSRs — free-running dither source (sec 5.2).
// =============================================================================

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        for (int i = 0; i < NUM_CH; i++)
            lfsr[i] <= LFSR_SEED0 ^ (16'(i) << 12) ^ 16'(i + 1);   // distinct, nonzero
    end else begin
        for (int i = 0; i < NUM_CH; i++)
            lfsr[i] <= {lfsr[i][14:0],
                        (lfsr[i][15] ^ lfsr[i][14] ^ lfsr[i][12] ^ lfsr[i][3])};
    end
end

// =============================================================================
// Main state machine
// =============================================================================

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state        <= IDLE;
        mode_active  <= 1'b0;
        pass_index   <= 2'b00;
        cal_err      <= 1'b0;
        fire_done    <= 1'b0;
        dac_sync     <= 1'b0;
        dac_valid    <= 8'h00;
        buf_clear    <= 8'h00;
        pass1a_result <= 12'h000;
        pass1b_result <= 12'h000;
        pass2_sum     <= 13'h0000;
        blk_exp_r       <= 5'd0;
        lane_bias_n_r   <= 4'd0;
        bfp_dwell       <= 4'd0;
        blk_scale_clamp <= 1'b0;
        stage_result       <= 32'sd0;
        stage_result_valid <= 1'b0;
        for (int i = 0; i < NUM_CH; i++)
            dac_data[i] <= 12'h000;
    end else begin

        // Default deassert
        dac_sync           <= 1'b0;
        fire_done          <= 1'b0;
        stage_result_valid <= 1'b0;
        buf_clear          <= 8'h00;
        dac_valid          <= 8'h00;

        case (state)

            // -----------------------------------------------------------------
            IDLE: begin
                mode_active <= 1'b0;
                pass_index  <= 2'b00;
                // Single trigger source: the one-cycle `fire` pulse. AUTO_FIRE
                // policy (rising edge of queue_full) lives in greencoyote_pilot_regs
                // and reaches us as that pulse — do not also level-trigger on
                // auto_fire/queue_full here or a still-full buffer re-runs the
                // reduction every time we return to IDLE.
                if (fire) begin
                    mode_active <= 1'b1;
                    bfp_dwell   <= 4'd0;
                    state       <= NORMALIZE;
                end
            end

            // -----------------------------------------------------------------
            // BFP NORMALIZE is now a BFP_LAT-stage pipeline (see the pipeline
            // block above). Its inputs are frozen for the whole reduction, so
            // we just dwell BFP_DWELL cycles for it to settle, then latch the
            // mutually time-aligned final-stage outputs in ONE cycle -- this
            // folds in the old PACK stage. A BFP-window clamp is sticky and
            // also raises cal_err (contract sec 7: "reduction still fires").
            NORMALIZE: begin
                if (bfp_dwell >= BFP_DWELL[3:0]) begin
                    blk_exp_r     <= be_p9;           // sec 5.4 reconstruction exp
                    lane_bias_n_r <= queue_depth;     // stable == popcount(full_p9)
                    for (int i = 0; i < NUM_CH; i++) begin
                        dac_data[i]  <= dac_packed_p9[i];
                        dac_valid[i] <= full_p9[i];   // only active channels
                    end
                    if (clamp_p9) begin
                        blk_scale_clamp <= 1'b1;
                        cal_err         <= 1'b1;
                    end
                    state <= FIRE;
                end else begin
                    bfp_dwell <= bfp_dwell + 4'd1;
                end
            end

            // -----------------------------------------------------------------
            // Assert dac_sync — all DACs load simultaneously
            // This is the optical fire strobe
            FIRE: begin
                dac_sync   <= 1'b1;
                pass_index <= 2'b00;    // Pass 1a
                state      <= CAPTURE;
            end

            // -----------------------------------------------------------------
            // Wait for ADC conversion complete (synchronized strobe)
            CAPTURE: begin
                // Advance on a valid conversion OR a conversion fault from
                // greencoyote_adc_if (a hung SPI frame) so the FSM cannot stall.
                if (adc_valid_sync || conv_fault_sync) begin
                    // ADC clip or conversion fault -> signal-integrity fault
                    if (adc_data_sync >= ADC_CLIP_THRESH || conv_fault_sync) begin
                        cal_err <= 1'b1;
                    end
                    pass1a_result <= adc_data_sync;
                    // sec 5.4 reconstruction: strip the offset-binary lane bias
                    // (n*2048) and undo the block shift -> Q17.14 partial sum.
                    stage_result  <= 32'($signed(adc_debiased)) <<< blk_exp_r;
                    state         <= PASS_CHECK;
                end
            end

            // -----------------------------------------------------------------
            // Determine if 14-GPU second pass needed
            PASS_CHECK: begin
                if (is_14gpu_mode) begin
                    // Need Pass 1b for remaining 6 GPUs
                    pass_index <= 2'b01;    // Pass 1b
                    state      <= LOAD_PASS2;
                end else begin
                    // 8-GPU or fewer — single pass complete
                    state <= DONE;
                end
            end

            // -----------------------------------------------------------------
            // Load Pass 1b — channels 0-5 carry Pass 1b data
            // Channels 6-7 already zero from pack stage
            LOAD_PASS2: begin
                // Pass 1b uses same buf_data — already loaded
                // Just re-fire with pass1b channel mapping
                // In hardware this would load a second set of buffers
                // For prototype: reuse channels 0-5 with new data
                dac_sync   <= 1'b1;
                state      <= FIRE_PASS2;
            end

            // -----------------------------------------------------------------
            FIRE_PASS2: begin
                dac_sync <= 1'b1;
                state    <= CAPTURE2;
            end

            // -----------------------------------------------------------------
            CAPTURE2: begin
                if (adc_valid_sync || conv_fault_sync) begin
                    if (adc_data_sync >= ADC_CLIP_THRESH || conv_fault_sync)
                        cal_err <= 1'b1;
                    pass1b_result <= adc_data_sync;
                    // Digital Stage 2 sum — no optical needed (raw ADC domain)
                    pass2_sum     <= {1'b0, pass1a_result} + {1'b0, adc_data_sync};
                    // sec 5.4 reconstruction for the Pass 1b sub-reduction (reuses
                    // this fire's blk_exp_r / lane_bias_n_r).
                    stage_result  <= 32'($signed(adc_debiased)) <<< blk_exp_r;
                    pass_index    <= 2'b10;     // Pass 2
                    state         <= DONE;
                end
            end

            // -----------------------------------------------------------------
            DONE: begin
                fire_done          <= 1'b1;
                stage_result_valid <= 1'b1;   // stage_result holds this reduction's
                                              // sec 5.4 reconstruction (last stage)
                mode_active        <= 1'b0;
                buf_clear          <= buf_full;    // Clear all filled buffers
                state              <= IDLE;
            end

            default: state <= IDLE;

        endcase
    end
end

// =============================================================================
// Streaming Tensor DMA optical beat generator (opt_clk / T_fire domain).
// Stall until dma_armed; then one seq_fire per opt_clk. Count FIRES_PER_WIN
// beats per accumulation window; pulse opt_window_done at each boundary.
// Operands the DMA presents (aligned by dma_operand_valid, one opt_clk after
// the corresponding seq_fire) are registered so a downstream optical-MAC model
// can consume them and the integration TB can check them.
// =============================================================================

localparam int OPT_FCW = $clog2(DMA_FIRES_PER_WIN);   // 9

logic [OPT_FCW-1:0]  opt_fire_cnt;
logic [DMA_ACT_W-1:0] act_data_q;         // last activation row consumed
logic [DMA_WT_W-1:0]  wt_data_q;          // last weight-operand set consumed
logic [31:0]          opt_rows_consumed;  // beats consumed since reset (TB / debug)

// One operand row is consumed per opt_clk while the feed is armed. seq_fire is
// combinational off dma_armed so it can never be high when the feed is not
// armed (no 1-cycle registered shadow at a window boundary).
assign seq_fire = dma_armed;

always_ff @(posedge opt_clk or negedge opt_rst_n) begin
    if (!opt_rst_n) begin
        opt_window_done   <= 1'b0;
        opt_fire_cnt      <= '0;
        act_data_q        <= '0;
        wt_data_q         <= '0;
        opt_rows_consumed <= '0;
    end else begin
        opt_window_done <= 1'b0;

        // capture the operands the DMA hands back (aligned by dma_operand_valid)
        if (dma_operand_valid) begin
            act_data_q        <= act_data;
            wt_data_q         <= wt_data;
            opt_rows_consumed <= opt_rows_consumed + 1'b1;
        end

        // count optical beats; pulse opt_window_done every FIRES_PER_WIN
        if (dma_armed) begin
            if (opt_fire_cnt == OPT_FCW'(DMA_FIRES_PER_WIN-1)) begin
                opt_fire_cnt    <= '0;
                opt_window_done <= 1'b1;
            end else begin
                opt_fire_cnt <= opt_fire_cnt + 1'b1;
            end
        end
    end
end

// =============================================================================
// Post-ADC de-bias term (sec 5.3/sec 5.4): adc_data_sync - lane_bias_n_r * 2048.
// lane_bias_n_r counts only the ACTIVE lanes that were offset-biased (not 8).
// =============================================================================

assign adc_debiased = $signed({6'd0, adc_data_sync})
                    - $signed({3'd0, lane_bias_n_r, 11'd0});   // n * 2048

// =============================================================================
// BFP scale status to pilot_regs (BLK_SCALE_STATUS @ 0xAC)
// =============================================================================

assign blk_exp_last = blk_exp_r;
assign lane_bias_n  = lane_bias_n_r;
// blk_scale_clamp is a sticky reg driven in the FSM.

// =============================================================================
// Result outputs
//   pass2_sum[11:0]      raw ADC-domain digital sum of the 14-GPU two-pass
//                        (internal; valid when pass_index == 2'b10)
//   stage_result         sec 5.4-reconstructed Q17.14 partial sum of the last
//                        captured stage, held until the next reduction; sampled
//                        by the downstream cascade / fabric on stage_result_valid
//                        (one cycle, coincident with fire_done). For the 14-GPU
//                        two-pass this reflects the Pass 1b sub-reduction; a full
//                        two-pass digital recombination is future work.
// =============================================================================

endmodule
