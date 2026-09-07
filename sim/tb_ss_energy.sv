// =============================================================================
// tb_ss_energy.sv  --  toggle-count harness for the single-slope readout
// digital back-end.  Runs ONE 256 ns observation window: the shared Gray TDC
// free-runs for T_RAMP ticks while all 64 channels fire once (staggered), and
// the calib pipe processes all 64 resulting codes.  Dumps VCD; sim/ss_energy.py
// converts per-net transition counts x ASAP7 cell caps -> fJ / MAC.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_ss_energy;
    localparam int NCH = 64, CB = 12, PB = 2, CHW = 6;
    localparam int T_RAMP = 4096;                 // 24 GS/s ticks in the window
    real PER = 16.667;                            // 6 GHz period, x100 time scale

    reg [3:0] clk_ph;
    reg       rst_n, cnt_en;
    reg  [NCH-1:0] fire;
    reg  [CHW-1:0] rd_ch;
    wire [CB+PB-1:0] rd_code;
    wire            rd_fired;
    reg             rd_clear;
    wire [NCH-1:0]  fired_mask;
    wire [CB-1:0]   gray_o;

    greencoyote_ss_tdc u_tdc (
        .clk_ph(clk_ph), .rst_n(rst_n), .cnt_en(cnt_en), .gray_o(gray_o),
        .fire(fire), .rd_ch(rd_ch), .rd_code(rd_code), .rd_fired(rd_fired),
        .rd_clear(rd_clear), .fired_mask(fired_mask));

    // calib pipe on the phase0 domain
    reg               cal_iv;
    reg  [13:0]       cal_code;
    reg  signed [31:0] c2, c1, c0;
    wire              cal_ov;
    wire [17:0]       x_hat;
    greencoyote_ss_calib u_cal (
        .clk(clk_ph[0]), .rst_n(rst_n), .in_valid(cal_iv),
        .code(cal_code), .c2(c2), .c1(c1), .c0(c0),
        .out_valid(cal_ov), .x_hat(x_hat));

    initial begin
        clk_ph = 4'b0000;
        forever begin
            #(PER/8) clk_ph[0]=1; #(PER/8) clk_ph[1]=1; #(PER/8) clk_ph[2]=1; #(PER/8) clk_ph[3]=1;
            #(PER/8) clk_ph[0]=0; #(PER/8) clk_ph[1]=0; #(PER/8) clk_ph[2]=0; #(PER/8) clk_ph[3]=0;
        end
    end

    integer i, t;
    initial begin
        $dumpfile("sim_out/ss_energy.vcd");
        $dumpvars(0, tb_ss_energy);
        rst_n=0; cnt_en=0; fire='0; rd_ch=0; rd_clear=0;
        cal_iv=0; cal_code=0; c2=32'sh0800_0000; c1=32'sh1000_0000; c0=32'shFFF0_0000; // ~Q4.28
        repeat (6) @(posedge clk_ph[0]);
        rst_n=1;
        @(posedge clk_ph[0]); cnt_en=1;

        // free-run T_RAMP ticks; each channel fires once, staggered ~ every 60 ticks
        for (t = 0; t < T_RAMP; t = t + 1) begin
            @(posedge clk_ph[0]);
            i = t / 60;
            if (i < NCH && (t % 60) == 0) fire[i] <= 1'b1;
            if (i < NCH && (t % 60) == 3) fire[i] <= 1'b0;
            // feed a calib conversion every 4 ticks (16 codes over the window is
            // enough to characterise the pipe; scale x4 in the analysis)
            if ((t % 4) == 0 && (t/4) < NCH) begin
                cal_iv   <= 1'b1;
                cal_code <= (t * 3) & 14'h3FFF;
                c2 <= $signed(32'sh0400_0000) + (t << 6);
                c1 <= $signed(32'sh1000_0000) + (t << 8);
                c0 <= $signed(32'shFFF0_0000) + (t << 4);
            end else cal_iv <= 1'b0;
        end
        cnt_en <= 1'b0;
        repeat (10) @(posedge clk_ph[0]);
        $display("=== tb_ss_energy: window complete, %0d channels fired ===", $countones(fired_mask));
        $finish;
    end
endmodule

`default_nettype wire
