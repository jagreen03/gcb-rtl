// =============================================================================
// GreenCoyote-Bay — SPI SAR ADC Interface (bench loopback)
// Project: ODIN_Bridge / Cascaded Optical Reduction Fabric
// =============================================================================
// Simple SPI master for a SAR ADC (mode 0: CPOL=0, CPHA=0), read-oriented.
// Chosen over a JESD204B/SerDes converter for the Task 3 bench so the optical
// physics is isolated from link-layer debugging.
//
// On `conversion_start` (a delayed fire strobe, so the DAC-driven optical value
// has settled):
//   A_IDLE -> A_SETTLE (SETTLE_CYCLES)
//          -> A_FRAME  : CS low, FRAME_BITS SCLK pulses; MOSI shifts CMD_WORD
//                        out MSB-first, MISO sampled on each rising edge
//          -> A_DONE   : CS high, present adc_data + one-cycle adc_valid
// A watchdog raises conv_fault (with a coincident adc_valid, data = 0) if the
// frame does not complete within TIMEOUT_CYCLES.
//
// adc_data / adc_valid / conv_fault feed greencoyote_photonic_sequencer, which
// carries them across its own 2-flop synchronizer into the CAPTURE states.
// =============================================================================

module greencoyote_adc_if #(
    parameter int          SCLK_DIV       = 2,      // clk cycles per SCLK half-period
    parameter int          SETTLE_CYCLES  = 6,      // conversion_start -> CS low
    parameter int          FRAME_BITS     = 16,     // SCLK pulses per conversion
    parameter int          RESULT_BITS    = 12,     // valid LSBs of the frame
    parameter logic [15:0] CMD_WORD       = 16'h0000,
    parameter int          TIMEOUT_CYCLES = 4096
)(
    input  logic        clk,
    input  logic        rst_n,
    input  logic        conversion_start,           // one-cycle strobe

    // SPI bus to the SAR ADC
    output logic        adc_sclk,
    output logic        adc_cs_n,
    output logic        adc_mosi,
    input  logic        adc_miso,

    // to the photonic sequencer
    output logic [11:0] adc_data,
    output logic        adc_valid,                  // one-cycle
    output logic        conv_fault                  // one-cycle, coincident with adc_valid on fault
);

    localparam int DIVW = (SCLK_DIV      <= 2) ? 1 : $clog2(SCLK_DIV);
    localparam int SETW = $clog2(SETTLE_CYCLES  + 1);
    localparam int BITW = $clog2(FRAME_BITS     + 1);
    localparam int TOW  = $clog2(TIMEOUT_CYCLES + 1);

    typedef enum logic [1:0] { A_IDLE, A_SETTLE, A_FRAME, A_DONE } a_state_t;
    a_state_t state;

    logic [DIVW-1:0] div_cnt;
    logic [SETW-1:0] settle_cnt;
    logic [BITW-1:0] bit_cnt;
    logic [TOW-1:0]  to_cnt;
    logic [15:0]     rx_shift;
    logic [15:0]     tx_shift;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= A_IDLE;
            adc_sclk   <= 1'b0;
            adc_cs_n   <= 1'b1;
            adc_mosi   <= 1'b0;
            adc_data   <= 12'h000;
            adc_valid  <= 1'b0;
            conv_fault <= 1'b0;
            div_cnt    <= '0;
            settle_cnt <= '0;
            bit_cnt    <= '0;
            to_cnt     <= '0;
            rx_shift   <= 16'h0000;
            tx_shift   <= 16'h0000;
        end else begin
            adc_valid  <= 1'b0;                              // one-cycle strobes default low
            conv_fault <= 1'b0;

            case (state)

                A_IDLE: begin
                    adc_sclk <= 1'b0;
                    adc_cs_n <= 1'b1;
                    adc_mosi <= 1'b0;
                    if (conversion_start) begin
                        settle_cnt <= '0;
                        to_cnt     <= '0;
                        tx_shift   <= CMD_WORD;
                        rx_shift   <= 16'h0000;
                        state      <= A_SETTLE;
                    end
                end

                A_SETTLE: begin
                    to_cnt <= to_cnt + 1'b1;
                    if (settle_cnt == SETTLE_CYCLES) begin
                        adc_cs_n <= 1'b0;                    // CS low: ADC presents MSB
                        adc_mosi <= tx_shift[15];
                        div_cnt  <= '0;
                        bit_cnt  <= '0;
                        adc_sclk <= 1'b0;
                        state    <= A_FRAME;
                    end else begin
                        settle_cnt <= settle_cnt + 1'b1;
                    end
                end

                A_FRAME: begin
                    to_cnt <= to_cnt + 1'b1;
                    if (to_cnt >= TIMEOUT_CYCLES) begin
                        adc_cs_n   <= 1'b1;                  // watchdog abort
                        adc_sclk   <= 1'b0;
                        adc_data   <= 12'h000;
                        adc_valid  <= 1'b1;
                        conv_fault <= 1'b1;
                        state      <= A_IDLE;
                    end else if (div_cnt == (SCLK_DIV - 1)) begin
                        div_cnt  <= '0;
                        adc_sclk <= ~adc_sclk;
                        if (~adc_sclk) begin                 // driving SCLK 0 -> 1 : rising edge
                            rx_shift <= {rx_shift[14:0], adc_miso};   // master samples MISO
                            bit_cnt  <= bit_cnt + 1'b1;
                            if (bit_cnt == (FRAME_BITS - 1)) begin
                                adc_cs_n <= 1'b1;
                                adc_sclk <= 1'b0;
                                state    <= A_DONE;
                            end
                        end else begin                       // driving SCLK 1 -> 0 : falling edge
                            tx_shift <= {tx_shift[14:0], 1'b0};
                            adc_mosi <= tx_shift[14];
                        end
                    end else begin
                        div_cnt <= div_cnt + 1'b1;
                    end
                end

                A_DONE: begin
                    adc_cs_n  <= 1'b1;
                    adc_sclk  <= 1'b0;
                    adc_data  <= rx_shift[RESULT_BITS-1:0];
                    adc_valid <= 1'b1;
                    state     <= A_IDLE;
                end

                default: state <= A_IDLE;

            endcase
        end
    end

endmodule
