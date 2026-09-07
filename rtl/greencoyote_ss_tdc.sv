// =============================================================================
// greencoyote_ss_tdc.sv
// Shared time-to-digital converter for the single-slope readout.
//
//  * one 12-bit Gray counter clocked at F_CLK (6 GHz nominal), distributed to
//    all channels -- Gray so the value crossing a channel's capture latch
//    changes one bit at a time (metastability-safe).
//  * 4 phase-latch banks : the Gray counter is re-sampled on each of the four
//    6 GHz clock phases (0/90/180/270 deg) -> 24 GS/s effective, 2 fine bits.
//  * per-channel {coarse, phase, fired} capture : on the rising edge of a
//    channel's comparator strobe `fire[ch]`, the earliest phase that observed
//    the strobe this coarse-cycle selects the phase code, and that phase's
//    Gray latch (converted to binary) is the coarse code.  Frozen until the
//    channel is cleared.
//  * simple indexed readout : {rd_ch} -> {rd_code[13:0]=coarse<<2|phase,
//    rd_fired}; rd_clear re-arms one channel.
//
//  code handed to greencoyote_ss_calib :  {coarse_bin[11:0], phase[1:0]}  (14b)
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module greencoyote_ss_tdc #(
    parameter int NCH   = 64,
    parameter int CB    = 12,          // coarse Gray/binary width
    parameter int PB    = 2,           // phase bits (4 phases)
    parameter int CHW   = $clog2(NCH)
) (
    // four 6 GHz clock phases, phase[0] is the reference
    input  wire [3:0]            clk_ph,
    input  wire                  rst_n,

    input  wire                  cnt_en,        // gate: run the Gray counter
    output wire [CB-1:0]         gray_o,        // distributed Gray value (debug)

    input  wire [NCH-1:0]        fire,          // per-channel comparator strobe (level, rising edge = crossing)

    // indexed readout
    input  wire [CHW-1:0]        rd_ch,
    output logic [CB+PB-1:0]     rd_code,       // {coarse_bin, phase}
    output logic                 rd_fired,
    input  wire                  rd_clear,      // 1-cycle (phase0) pulse: re-arm rd_ch
    output logic [NCH-1:0]       fired_mask
);
    // ---------------------------------------------------------------------
    // 1.  12-bit binary counter on phase0, Gray view distributed
    // ---------------------------------------------------------------------
    logic [CB-1:0] bin_cnt;
    always_ff @(posedge clk_ph[0] or negedge rst_n) begin
        if (!rst_n)      bin_cnt <= '0;
        else if (cnt_en) bin_cnt <= bin_cnt + 1'b1;
    end
    wire [CB-1:0] gray_cnt = bin_cnt ^ (bin_cnt >> 1);
    assign gray_o = gray_cnt;

    // gray -> binary (unrolled xor-scan)
    function automatic [CB-1:0] g2b(input [CB-1:0] g);
        integer i;
        begin
            g2b[CB-1] = g[CB-1];
            for (i = CB-2; i >= 0; i = i - 1)
                g2b[i] = g2b[i+1] ^ g[i];
        end
    endfunction

    // ---------------------------------------------------------------------
    // 2.  four phase latches of the Gray counter
    // ---------------------------------------------------------------------
    logic [3:0][CB-1:0] gray_lat;     // packed: gray_lat[phase]
    genvar p;
    generate
        for (p = 0; p < 4; p = p + 1) begin : g_phase
            always_ff @(posedge clk_ph[p] or negedge rst_n) begin
                if (!rst_n) gray_lat[p] <= '0;
                else        gray_lat[p] <= gray_cnt;   // sample the live Gray value
            end
        end
    endgenerate

    // ---------------------------------------------------------------------
    // 3.  per-channel capture  (low-power CIS-style)
    //
    //  Each channel samples `fire[ch]` on all 4 phases -> a 4-bit thermometer
    //  `fs[c]`.  On the phase0 boundary, if the channel is un-fired and the
    //  thermometer just rose, it latches:
    //     * the SHARED phase0 Gray latch  gray_lat[0]   (one 12-bit D net,
    //       broadcast to 64 enabled registers -- NO per-channel 4:1 mux, so
    //       zero per-channel dynamic activity between conversions), and
    //     * the 4-bit thermometer itself.
    //  gray->bin and the phase-code derivation run ONCE, in the readout mux.
    // ---------------------------------------------------------------------
    logic [NCH-1:0][3:0]    fs;          // fire sampled per phase
    logic [NCH-1:0][3:0]    fs_q;        // previous phase0 snapshot (edge detect)
    logic [NCH-1:0]         fired;
    logic [NCH-1:0][CB-1:0] cap_gray;    // gray_lat[0] frozen at the fire
    logic [NCH-1:0][3:0]    cap_therm;   // fs[c] frozen at the fire

    genvar c, q;
    generate
        for (c = 0; c < NCH; c = c + 1) begin : g_ch
            for (q = 0; q < 4; q = q + 1) begin : g_fs
                always_ff @(posedge clk_ph[q] or negedge rst_n) begin
                    if (!rst_n) fs[c][q] <= 1'b0;
                    else        fs[c][q] <= fire[c];
                end
            end

            wire new_edge = |(fs[c] & ~fs_q[c]);     // any phase rose this cycle

            always_ff @(posedge clk_ph[0] or negedge rst_n) begin
                if (!rst_n) begin
                    fired[c]     <= 1'b0;
                    cap_gray[c]  <= '0;
                    cap_therm[c] <= 4'd0;
                    fs_q[c]      <= 4'd0;
                end else begin
                    fs_q[c] <= fs[c];
                    if (rd_clear && (rd_ch == c[CHW-1:0])) begin
                        fired[c] <= 1'b0;
                    end else if (!fired[c] && new_edge) begin
                        fired[c]     <= 1'b1;
                        cap_gray[c]  <= gray_lat[0];      // shared broadcast net
                        cap_therm[c] <= fs[c];
                    end
                end
            end

            assign fired_mask[c] = fired[c];
        end
    endgenerate

    // ---------------------------------------------------------------------
    // 4.  indexed readout : one gray->bin, one phase decode
    // ---------------------------------------------------------------------
    function automatic [PB-1:0] therm2phase(input [3:0] th);
        // number of phases that had already sampled '1' at phase0 -> sub-tick
        // position.  more 1s  ->  strobe rose earlier in the tick  ->  lower
        // phase code.  th==0 (shouldn't occur for a fired channel) -> 3.
        integer n; begin
            n = th[0] + th[1] + th[2] + th[3];
            therm2phase = (n == 0) ? 2'd3 : PB'(4 - n);
        end
    endfunction

    always_comb begin
        rd_code  = {g2b(cap_gray[rd_ch]), therm2phase(cap_therm[rd_ch])};
        rd_fired = fired[rd_ch];
    end

endmodule

`default_nettype wire
