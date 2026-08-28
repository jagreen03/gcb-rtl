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
    input  logic [11:0] dark_offset,            // Photodetector dark current
    input  logic [7:0]  trim_ch [0:7],          // Per-channel gain coefficients

    output logic        mode_active,            // Reduction in progress
    output logic [1:0]  pass_index,             // 00=Pass1a 01=Pass1b 10=Pass2
    output logic [3:0]  queue_depth,            // Channels with data ready
    output logic        cal_err,                // ADC clip or integrity fault
    output logic        fire_done,              // Reduction complete pulse
    output logic        queue_full,             // All active channels ready

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
    input  logic        adc_valid               // ADC conversion complete
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

// =============================================================================
// State machine definition
// =============================================================================

typedef enum logic [3:0] {
    IDLE        = 4'h0,
    NORMALIZE   = 4'h1,    // Apply trim_ch gain and dark_offset subtraction
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

logic [11:0] normalized [0:7];      // Post dark-offset, pre-pack
logic [11:0] packed     [0:7];      // Post precision packing, DAC-ready
logic [11:0] pass1a_result;         // ADC result from Pass 1a
logic [11:0] pass1b_result;         // ADC result from Pass 1b
logic [12:0] pass2_sum;             // Digital sum of Pass 1a + 1b (13-bit)
logic        is_14gpu_mode;         // Set when buf_full[5:0] all set — 14 GPU
logic [3:0]  active_channels;       // Count of channels with data

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
// Gain trim normalization — digital multiply before DAC
// Applied as: normalized = (buf_data * trim_ch) >> 8 - dark_offset
// =============================================================================

always_comb begin
    for (int i = 0; i < NUM_CH; i++) begin
        automatic logic [19:0] trimmed;
        trimmed = (buf_data[i][11:0] * trim_ch[i]);    // 12b * 8b = 20b
        normalized[i] = trimmed[19:8] - dark_offset;   // Scale back to 12b
    end
end

// =============================================================================
// Precision packing — map normalized value into 12-bit DAC window
// based on MODE_SEL. Zero-pads inactive channels.
// =============================================================================

always_comb begin
    for (int i = 0; i < NUM_CH; i++) begin
        if (!buf_full[i]) begin
            packed[i] = 12'h000;    // Zero-pad inactive channel
        end else begin
            case (mode_sel)
                MODE_INT4: packed[i] = {8'h00, normalized[i][3:0]};    // 4-bit in LSBs
                MODE_FP4:  packed[i] = {6'h00, normalized[i][5:0]};    // 6-bit window
                MODE_FP8:  packed[i] = normalized[i];                   // Full 12-bit
                MODE_BF16: packed[i] = normalized[i];                   // Full 12-bit
                default:   packed[i] = normalized[i];
            endcase
        end
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
        for (int i = 0; i < NUM_CH; i++)
            dac_data[i] <= 12'h000;
    end else begin

        // Default deassert
        dac_sync  <= 1'b0;
        fire_done <= 1'b0;
        buf_clear <= 8'h00;
        dac_valid <= 8'h00;

        case (state)

            // -----------------------------------------------------------------
            IDLE: begin
                mode_active <= 1'b0;
                pass_index  <= 2'b00;
                if (fire || (auto_fire && queue_full)) begin
                    mode_active <= 1'b1;
                    state       <= NORMALIZE;
                end
            end

            // -----------------------------------------------------------------
            // Normalization is combinational — one cycle to register results
            NORMALIZE: begin
                state <= PACK;
            end

            // -----------------------------------------------------------------
            // Packing is combinational — one cycle to register and load DACs
            PACK: begin
                for (int i = 0; i < NUM_CH; i++) begin
                    dac_data[i] <= packed[i];
                    dac_valid[i] <= buf_full[i];    // Only valid channels
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
            // Wait for ADC conversion complete
            CAPTURE: begin
                if (adc_valid) begin
                    // Check for ADC clip — signal integrity fault
                    if (adc_data >= ADC_CLIP_THRESH) begin
                        cal_err <= 1'b1;
                    end
                    pass1a_result <= adc_data;
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
                if (adc_valid) begin
                    if (adc_data >= ADC_CLIP_THRESH)
                        cal_err <= 1'b1;
                    pass1b_result <= adc_data;
                    // Digital Stage 2 sum — no optical needed
                    pass2_sum     <= {1'b0, pass1a_result} + {1'b0, adc_data};
                    pass_index    <= 2'b10;     // Pass 2
                    state         <= DONE;
                end
            end

            // -----------------------------------------------------------------
            DONE: begin
                fire_done   <= 1'b1;
                mode_active <= 1'b0;
                buf_clear   <= buf_full;    // Clear all filled buffers
                state       <= IDLE;
            end

            default: state <= IDLE;

        endcase
    end
end

// =============================================================================
// Pass 2 result output
// Available on pass2_sum[11:0] when pass_index == 2'b10
// Connect to result buffer or broadcast back to GPU channels
// =============================================================================

endmodule
