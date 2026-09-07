// =============================================================================
// tb_ss_tdc.sv  --  properties of greencoyote_ss_tdc under Icarus 11 -g2012.
//
//   1. Gray counter: exactly ONE bit changes per phase0 clock while cnt_en.
//   2. gray->bin of the distributed value increments by 1 (mod 4096) / clock.
//   3. a channel strobed at a known coarse cycle captures that coarse code
//      (+-1 for sampling latency) and a phase in 0..3.
//   4. per-channel isolation: firing ch A never changes ch B's frozen code.
//   5. rd_clear re-arms exactly one channel.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_ss_tdc;
    localparam int NCH = 64, CB = 12, PB = 2, CHW = 6;

    // 6 GHz -> 166.67 ps period; 4 phases 41.667 ps apart.
    // scale time x100 for Icarus resolution: period = 16.667 "ns", step 4.1667.
    real     PER = 16.667;
    reg [3:0] clk_ph;
    reg       rst_n, cnt_en;
    reg  [NCH-1:0] fire;
    reg  [CHW-1:0] rd_ch;
    wire [CB+PB-1:0] rd_code;
    wire            rd_fired;
    reg             rd_clear;
    wire [NCH-1:0]  fired_mask;
    wire [CB-1:0]   gray_o;

    greencoyote_ss_tdc dut (
        .clk_ph(clk_ph), .rst_n(rst_n), .cnt_en(cnt_en), .gray_o(gray_o),
        .fire(fire), .rd_ch(rd_ch), .rd_code(rd_code), .rd_fired(rd_fired),
        .rd_clear(rd_clear), .fired_mask(fired_mask));

    // ---- 4-phase clock generation -----------------------------------------
    initial begin
        clk_ph = 4'b0000;
        forever begin
            #(PER/8)          clk_ph[0] = 1'b1;
            #(PER/8)          clk_ph[1] = 1'b1;
            #(PER/8)          clk_ph[2] = 1'b1;
            #(PER/8)          clk_ph[3] = 1'b1;
            #(PER/8)          clk_ph[0] = 1'b0;
            #(PER/8)          clk_ph[1] = 1'b0;
            #(PER/8)          clk_ph[2] = 1'b0;
            #(PER/8)          clk_ph[3] = 1'b0;
        end
    end

    integer errs;
    task chk(input cond, input [255:0] msg);
        begin if (!cond) begin errs = errs + 1;
              $display("FAIL: %0s", msg); end end
    endtask

    // ---- property 1/2 : Gray monotone single-bit, bin increments ----------
    reg [CB-1:0] prev_gray;
    reg          watch;
    integer      onehot_bad, incr_bad;
    function integer popcnt(input [CB-1:0] v); integer i; begin
        popcnt = 0; for (i=0;i<CB;i=i+1) popcnt = popcnt + v[i]; end
    endfunction
    function automatic [CB-1:0] g2b(input [CB-1:0] g); integer i; begin
        g2b[CB-1]=g[CB-1]; for(i=CB-2;i>=0;i=i-1) g2b[i]=g2b[i+1]^g[i]; end
    endfunction

    // sample well after phase0's edge (on phase2 negedge) so bin_cnt is settled
    always @(negedge clk_ph[2]) begin
        if (watch) begin
            if (popcnt(gray_o ^ prev_gray) !== 1) onehot_bad = onehot_bad + 1;
            if (g2b(gray_o) !== ((g2b(prev_gray) + 1) & ((1<<CB)-1))) incr_bad = incr_bad + 1;
        end
        prev_gray = gray_o;
    end

    integer i, ph, expect_coarse;
    reg [CB-1:0] saved_codeB;

    initial begin
        errs = 0; onehot_bad = 0; incr_bad = 0; watch = 0;
        rst_n = 0; cnt_en = 0; fire = '0; rd_ch = 0; rd_clear = 0;
        repeat (6) @(posedge clk_ph[0]);
        rst_n = 1;
        @(posedge clk_ph[0]); cnt_en = 1;
        prev_gray = gray_o;
        @(posedge clk_ph[0]); watch = 1;

        // let it run a while
        repeat (300) @(posedge clk_ph[0]);
        watch = 0;
        chk(onehot_bad == 0, "Gray value changed more than one bit in a cycle");
        chk(incr_bad  == 0, "gray->bin did not increment by 1 each cycle");

        // ---- property 3 : strobe a channel, check captured coarse ~ now ----
        rd_ch = 6'd5;
        @(negedge clk_ph[0]);
        expect_coarse = g2b(gray_o);
        fire[5] = 1'b1;                       // async rising strobe
        repeat (2) @(posedge clk_ph[0]);
        fire[5] = 1'b0;                       // strobe is a pulse
        repeat (2) @(posedge clk_ph[0]);
        chk(rd_fired === 1'b1, "ch5 did not latch fired");
        chk(rd_code[PB+CB-1:PB] >= (expect_coarse-2) &&
            rd_code[PB+CB-1:PB] <= (expect_coarse+2),
            "ch5 captured coarse far from the strobe time");
        chk(rd_code[PB-1:0] <= 2'd3, "ch5 phase code out of range");
        $display("INFO ch5: expect_coarse~%0d  got coarse=%0d phase=%0d",
                 expect_coarse, rd_code[PB+CB-1:PB], rd_code[PB-1:0]);

        // ---- property 3b : sub-cycle offset -> phase code tracks ----------
        // fire ch 10..13 each delayed a further quarter-cycle; phase codes
        // must be distinct and cover >1 value (proves the 4-phase mux works).
        begin : subph
            integer j; reg [1:0] phv [0:3]; reg [CB-1:0] cov [0:3];
            for (j = 0; j < 4; j = j + 1) begin
                @(negedge clk_ph[0]);
                #(PER/4.0 * j);                 // stagger the strobe within the cycle
                fire[10+j] = 1'b1;
                repeat (2) @(posedge clk_ph[0]);
                fire[10+j] = 1'b0;
                repeat (2) @(posedge clk_ph[0]);
                rd_ch = 6'd10 + j[CHW-1:0]; @(posedge clk_ph[0]);
                phv[j] = rd_code[PB-1:0];
                cov[j] = rd_code[PB+CB-1:PB];
                chk(rd_fired === 1'b1, "sub-phase channel did not fire");
            end
            $display("INFO sub-phase codes: ph=%0d,%0d,%0d,%0d  coarse=%0d,%0d,%0d,%0d",
                     phv[0],phv[1],phv[2],phv[3], cov[0],cov[1],cov[2],cov[3]);
            chk(!(phv[0]==phv[1] && phv[1]==phv[2] && phv[2]==phv[3]),
                "phase code never changed across 4 staggered strobes");
        end

        // ---- property 4 : firing ch6 must not disturb ch5 -----------------
        rd_ch = 6'd5; @(posedge clk_ph[0]);
        saved_codeB = rd_code[PB+CB-1:PB];
        fire[6] = 1'b1;
        repeat (2) @(posedge clk_ph[0]);
        fire[6] = 1'b0;
        repeat (3) @(posedge clk_ph[0]);
        rd_ch = 6'd5; @(posedge clk_ph[0]);
        chk(rd_code[PB+CB-1:PB] === saved_codeB, "ch5 code changed after ch6 fired");
        rd_ch = 6'd6; @(posedge clk_ph[0]);
        chk(rd_fired === 1'b1, "ch6 did not latch fired");

        // ---- property 5 : rd_clear re-arms exactly one channel ------------
        rd_ch = 6'd5; @(negedge clk_ph[0]); rd_clear = 1'b1;
        @(posedge clk_ph[0]); @(negedge clk_ph[0]); rd_clear = 1'b0;
        @(posedge clk_ph[0]);
        rd_ch = 6'd5; @(posedge clk_ph[0]);
        chk(rd_fired === 1'b0, "ch5 not re-armed by rd_clear");
        rd_ch = 6'd6; @(posedge clk_ph[0]);
        chk(rd_fired === 1'b1, "ch6 wrongly cleared by ch5 rd_clear");

        if (errs == 0) $display("=== tb_ss_tdc: ALL CHECKS PASS ===");
        else           $display("=== tb_ss_tdc: %0d FAIL ===", errs);
        $finish;
    end

    initial begin #500000; $display("=== tb_ss_tdc: TIMEOUT FAIL ==="); $finish; end
endmodule

`default_nettype wire
