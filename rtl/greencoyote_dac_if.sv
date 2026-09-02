// =============================================================================
// GreenCoyote-Bay — Parallel DAC Interface (bench loopback)
// Project: ODIN_Bridge / Cascaded Optical Reduction Fabric
// =============================================================================
// Drives a single 14-bit parallel DAC bus for the Task 3 discrete bench cell.
// Deliberately a bench stimulus block: on each `fire` strobe it advances an
// internal LFSR test-vector generator, then time-multiplexes NUM_CH channels of
// a trim-scaled 14-bit word onto {data, channel-select, write-strobe} — generic
// parallel-DAC timing (DAC5672 / AD9767 class), no SerDes.
//
// This isolates the optical path from the sequencer's computed data: known
// pseudo-random vectors go out the DAC, come back through the SPI SAR ADC
// (greencoyote_adc_if), and the optical transfer is what is measured.
// =============================================================================

module greencoyote_dac_if #(
    parameter int          NUM_CH    = 8,
    parameter int          DATA_W    = 14,
    parameter logic [15:0] LFSR_SEED = 16'hACE1
)(
    input  logic                 clk,
    input  logic                 rst_n,
    input  logic                 fire,                       // one-cycle strobe (dac_sync)
    input  logic [7:0]           trim_ch [0:NUM_CH-1],       // per-channel gain, 0xFF ~ unity

    output logic [DATA_W-1:0]    dac_p_data,                 // 14-bit parallel word
    output logic [2:0]           dac_p_chan,                 // target channel 0..NUM_CH-1
    output logic                 dac_p_clk,                  // update strobe (data valid on rising)
    output logic                 dac_p_wr_n,                 // write enable, active low
    output logic                 dac_load_done               // pulse: all NUM_CH words clocked out
);

    // ---- internal LFSR test-vector generator ---------------------------------
    // 16-bit maximal-length LFSR, x^16 + x^15 + x^13 + x^4 + 1, advanced per fire
    logic [15:0] lfsr;
    logic        lfsr_fb;
    assign lfsr_fb = lfsr[15] ^ lfsr[14] ^ lfsr[12] ^ lfsr[3];

    logic [13:0] test_base;
    assign test_base = lfsr[13:0];                           // pseudo-random 14-bit base

    // trim-scaled word for the current channel: (test_base * trim) >> 8
    logic [3:0]  ch;                                         // 0 .. NUM_CH
    logic [21:0] scaled;
    assign scaled = test_base * trim_ch[ch[2:0]];            // 14b * 8b = 22b

    typedef enum logic [1:0] { DAC_IDLE, DAC_DRIVE, DAC_STROBE } dac_state_t;
    dac_state_t state;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lfsr          <= LFSR_SEED;
            state         <= DAC_IDLE;
            ch            <= 4'd0;
            dac_p_data    <= '0;
            dac_p_chan    <= 3'd0;
            dac_p_clk     <= 1'b0;
            dac_p_wr_n    <= 1'b1;
            dac_load_done <= 1'b0;
        end else begin
            dac_p_clk     <= 1'b0;                           // strobes default low
            dac_load_done <= 1'b0;

            case (state)

                DAC_IDLE: begin
                    dac_p_wr_n <= 1'b1;
                    if (fire) begin
                        lfsr  <= {lfsr[14:0], lfsr_fb};      // advance the test vector
                        ch    <= 4'd0;
                        state <= DAC_DRIVE;
                    end
                end

                DAC_DRIVE: begin
                    dac_p_data <= scaled[21:8];              // >> 8, keep 14 bits
                    dac_p_chan <= ch[2:0];
                    dac_p_wr_n <= 1'b0;
                    state      <= DAC_STROBE;
                end

                DAC_STROBE: begin
                    dac_p_clk <= 1'b1;                       // latch on this rising edge
                    // hold dac_p_wr_n low through every strobe; DAC_IDLE raises it
                    if (ch == NUM_CH - 1) begin
                        dac_load_done <= 1'b1;
                        state         <= DAC_IDLE;
                    end else begin
                        ch    <= ch + 4'd1;
                        state <= DAC_DRIVE;
                    end
                end

                default: state <= DAC_IDLE;

            endcase
        end
    end

endmodule
