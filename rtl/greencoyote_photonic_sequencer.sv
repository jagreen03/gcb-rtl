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
//   IDLE → NORMALIZE → PACK → FIRE → CAPTURE → PASS_CHECK → REDUCE2 → DONE
//
// NORMALIZE now runs the block-floating-point (BFP) pass of
// carry_save_streaming_contract.md sec 5.1: derive a shared block exponent from the
// active-lane magnitudes, arithmetic-shift each 32-bit Q17.14 accumulator word
// down into the 12-bit DAC window, round per ROUND_MODE (sec 5.2), add the
// offset-binary lane bias (sec 5.3), and clamp. The shared exponent and the active
// lane count are latched for the post-ADC reconstruction in CAPTURE/CAPTURE2
// (sec 5.4). This replaces the earlier `buf_data[i][11:0]` static truncation.
// =============================================================================

module greencoyote_photonic_sequencer (
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
    input  logic        conv_fault              // ADC conversion fault (1-cycle, with adc_valid)
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
    NORMALIZE   = 4'h1,    // Run the BFP pass; latch blk_exp and active lane count
    PACK        = 4'h2,    // Apply precision packing into 12-bit DAC window
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

logic [11:0] bfp_code    [0:7];     // BFP window output, offset-binary DAC code (sec 5.1)
logic [11:0] dac_packed  [0:7];     // Post precision packing, DAC-ready
logic [11:0] pass1a_result;         // Raw ADC result from Pass 1a
logic [11:0] pass1b_result;         // Raw ADC result from Pass 1b
logic [12:0] pass2_sum;             // Digital sum of raw Pass 1a + 1b (13-bit)
logic        is_14gpu_mode;         // Set when buf_full[5:0] all set — 14 GPU

// --- BFP forward-path nets (combinational, from live buf_data/buf_full) -------
logic signed [31:0] acc_word  [0:7];   // trim-scaled Q17.14 accumulator word per lane
logic        [31:0] lane_mag  [0:7];   // |acc_word|
logic        [31:0] blk_mag_max;       // max magnitude across ACTIVE lanes
logic        [5:0]  blk_msb_idx;       // msb_index(blk_mag_max), 0..31
logic        [4:0]  bfp_blk_exp;       // shared block exponent this cycle (sec 5.1 step 2)
logic               bfp_any_clamp;     // any active lane hit the [0,4095] clamp

// --- BFP state latched at NORMALIZE, consumed in CAPTURE/CAPTURE2 (sec 5.4) ------
logic [4:0]  blk_exp_r;             // shared block exponent for the in-flight fire
logic [3:0]  lane_bias_n_r;         // active lane count (= queue_depth) at fire
// stage_result (sec 5.4 reconstruction) is now a module output port.
logic signed [17:0] adc_debiased;  // adc_data_sync - lane_bias_n_r*2048 (pre-shift)

// --- Per-lane stochastic-rounding dither -------------------------------------
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
// Per-lane gain trim — applied to the FULL 32-bit accumulator word, not the
// old 12-bit truncation. trim_ch is the per-channel MDL calibration coefficient
// (0xFF ~ unity: 255/256). Result stays Q17.14 two's-complement.
// =============================================================================

always_comb begin : trim_scale
    logic        [31:0] bd;
    logic signed [40:0] prod;
    logic signed [31:0] w;
    for (int i = 0; i < NUM_CH; i++) begin
        bd          = buf_data[i];
        // 32b signed * 9b unsigned, evaluated in 41b, then >>> 8 back to Q17.14
        prod        = $signed(bd) * $signed({1'b0, trim_ch[i]});
        w           = 32'(prod >>> 8);
        acc_word[i] = w;
        lane_mag[i] = w[31] ? (~w + 32'd1) : w;
    end
end

// =============================================================================
// BFP block exponent — carry_save_streaming_contract.md sec 5.1 steps 1-2.
//   mag_max  = max |acc_word[k]| over ACTIVE lanes
//   blk_exp  = clamp( msb_index(mag_max) - (11 - SAT_GUARD - NOISE_HEADROOM), 0, 31 )
// msb_index is a 32-bit priority encoder (one level of logic).
// =============================================================================

function automatic logic [5:0] msb_index (input logic [31:0] v);
    msb_index = 6'd0;
    for (int b = 0; b < 32; b++)
        if (v[b]) msb_index = b[5:0];
endfunction

always_comb begin : blk_max
    blk_mag_max = 32'd0;
    for (int i = 0; i < NUM_CH; i++)
        if (buf_full[i] && lane_mag[i] > blk_mag_max)
            blk_mag_max = lane_mag[i];
    blk_msb_idx = msb_index(blk_mag_max);
end

always_comb begin : bfp_exp
    // window position: 11 - SAT_GUARD - NOISE_HEADROOM, in [3..11]
    int win;
    int be_raw;
    win    = 11 - int'(sat_guard) - int'(noise_headroom);
    be_raw = int'(blk_msb_idx) - win;
    if      (be_raw <= 0)  bfp_blk_exp = 5'd0;
    else if (be_raw >= 31) bfp_blk_exp = 5'd31;
    else                   bfp_blk_exp = 5'(be_raw);
end

// =============================================================================
// BFP per-lane window — sec 5.1 step 3, sec 5.2 rounding, sec 5.3 offset-binary.
//   shifted = acc_word[k] >>> blk_exp            (arithmetic, floor toward -inf)
//   rounded = shifted + round_up(round_mode, discarded frac)
//   biased  = rounded + 2048                     (active lanes only)
//   code    = clamp(biased, 0, 4095)
// Inactive lanes emit code 0 and are NOT offset-biased.
// =============================================================================

always_comb begin : bfp_window
    logic [4:0]         be;
    logic signed [32:0] shifted;
    logic [31:0]        frac_mask;
    logic [31:0]        frac;
    logic               guard, sticky, round_up;
    logic signed [33:0] biased;

    be            = bfp_blk_exp;
    bfp_any_clamp = 1'b0;

    for (int i = 0; i < NUM_CH; i++) begin
        if (!buf_full[i]) begin
            bfp_code[i] = 12'h000;              // zero-pad, no bias
        end else begin
            shifted   = $signed(acc_word[i]) >>> be;
            frac_mask = (be == 5'd0) ? 32'd0 : ((32'd1 << be) - 32'd1);
            frac      = acc_word[i] & frac_mask;          // discarded low bits (>= 0)
            guard     = (be == 5'd0) ? 1'b0 : frac[be - 5'd1];
            sticky    = (be <= 5'd1) ? 1'b0
                                     : |(frac & (frac_mask >> 1));

            unique case (round_mode)
                ROUND_RNE:   round_up = guard & (sticky | shifted[0]);
                ROUND_STOCH: round_up = ({16'd0, lfsr[i]} & frac_mask) < frac;
                default:     round_up = 1'b0;             // TRUNC and 2'b11
            endcase

            biased = 34'($signed(shifted)) + $signed(34'(round_up))
                   + $signed(34'(OFFSET_BIN));

            if (biased < 0) begin
                bfp_code[i]   = 12'h000;
                bfp_any_clamp = 1'b1;
            end else if (biased > DAC_CODE_MAX) begin
                bfp_code[i]   = 12'hFFF;
                bfp_any_clamp = 1'b1;
            end else begin
                bfp_code[i] = biased[11:0];
            end
        end
    end
end

// =============================================================================
// Precision packing — map the BFP window code into the DAC word by MODE_SEL,
// after the sec 5 block scaling (contract sec 4.3). Zero-pads inactive channels.
// =============================================================================

always_comb begin : precision_pack
    logic [11:0] c;
    for (int i = 0; i < NUM_CH; i++) begin
        c = bfp_code[i];
        if (!buf_full[i]) begin
            dac_packed[i] = 12'h000;    // Zero-pad inactive channel
        end else begin
            case (mode_sel)
                MODE_INT4: dac_packed[i] = {8'h00, c[3:0]};    // 4-bit in LSBs
                MODE_FP4:  dac_packed[i] = {6'h00, c[5:0]};    // 6-bit window
                MODE_FP8:  dac_packed[i] = c;                   // Full 12-bit
                MODE_BF16: dac_packed[i] = c;                   // Full 12-bit
                default:   dac_packed[i] = c;
            endcase
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
                    state       <= NORMALIZE;
                end
            end

            // -----------------------------------------------------------------
            // BFP pass is combinational — one cycle to snapshot the shared
            // block exponent and the active lane count for this fire (sec 5.1,
            // consumed by the post-ADC reconstruction in sec 5.4).
            NORMALIZE: begin
                blk_exp_r     <= bfp_blk_exp;
                lane_bias_n_r <= queue_depth;
                state         <= PACK;
            end

            // -----------------------------------------------------------------
            // Packing is combinational — one cycle to register and load DACs.
            // A BFP window clamp is sticky and also raises cal_err (contract sec 7:
            // "reduction still fires").
            PACK: begin
                for (int i = 0; i < NUM_CH; i++) begin
                    dac_data[i] <= dac_packed[i];
                    dac_valid[i] <= buf_full[i];    // Only valid channels
                end
                if (bfp_any_clamp) begin
                    blk_scale_clamp <= 1'b1;
                    cal_err         <= 1'b1;
                end
                state <= FIRE;
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
