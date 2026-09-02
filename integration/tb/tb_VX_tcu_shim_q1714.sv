// =============================================================================
// tb_VX_tcu_shim_q1714.sv — full-shim testbench with an M_AXIS_CS sink
// Project: GreenCoyote-Bay / ODIN_Bridge
// =============================================================================
// Drives VX_tcu_shim_q1714 end to end:
//   * a result_if driver pushes "records" = {NUM_LANES words, fmt_d, is_tf}
//     with random inter-record gaps;
//   * an M_AXIS_CS sink randomly stalls TREADY;
//   * a ring-buffer scoreboard checks, for each is_tile_final record: exactly
//     NUM_LANES beats, TDATA == golden conv_word, TUSER = {nan, ovf, lane},
//     TLAST only on the last lane, TID == cfg_tid, TKEEP == F, and in order;
//     for a non-tile-final record: ZERO beats.
//   * the shim's own `RUNTIME_ASSERT`s are active (-DSIMULATION) and $fatal on
//     violation.
//
// Golden model: conv_word from VX_tcu_q1714_convert_pkg, already proven
// bit-exact by tb_VX_tcu_q1714_convert.sv. Plumbing (framing / ordering /
// backpressure) is round-mode independent, so this TB exercises SHIM_ROUND="RNE";
// TRUNC arithmetic is covered by the conversion TB.
//
// Standalone build (Icarus >= 11), see run_shim_tb.sh:
//   iverilog -g2012 -DSIMULATION -I stubs \
//     ../VX_tcu_q1714_convert_pkg.sv stubs/vx_stubs.sv \
//     ../VX_tcu_shim_q1714.sv tb_VX_tcu_shim_q1714.sv
// =============================================================================

`timescale 1ns/1ps
`include "VX_define.vh"

module tb_VX_tcu_shim_q1714;
    import VX_tcu_q1714_convert_pkg::*;
    import VX_tcu_pkg::*;                     // tcu_result_t, NUM_TCU_LANES

    localparam int NUM_LANES = NUM_TCU_LANES; // = 8 in the stub
    localparam int TID_W     = 4;
    localparam logic [TID_W-1:0] CFG_TID = 4'hA;
    localparam int N_RECORDS  = 1500;

    // ---------------------------------------------------------------------
    logic clk = 0, reset = 1;
    always #5 clk = ~clk;

    VX_result_if rif ();
    logic        rif_is_tf;
    logic [4:0]  rif_fmt_d;
    logic [5:0]  int_prescale;

    logic              axi_tready;
    wire               axi_tvalid, axi_tlast;
    wire [31:0]        axi_tdata;
    wire [TID_W-1:0]   axi_tid;
    wire [5:0]         axi_tuser;
    wire [3:0]         axi_tkeep;

    VX_tcu_shim_q1714 #(
        .INSTANCE_ID ("shimtb"),
        .NUM_LANES   (NUM_LANES),
        .TID_W       (TID_W),
        .SHIM_ROUND  ("RNE")
    ) dut (
        .clk          (clk),
        .reset        (reset),
        .result_if    (rif),
        .is_tile_final(rif_is_tf),
        .fmt_d        (rif_fmt_d),
        .int_prescale (int_prescale),
        .cfg_tid      (CFG_TID),
        .m_axis_tvalid(axi_tvalid),
        .m_axis_tready(axi_tready),
        .m_axis_tdata (axi_tdata),
        .m_axis_tlast (axi_tlast),
        .m_axis_tid   (axi_tid),
        .m_axis_tuser (axi_tuser),
        .m_axis_tkeep (axi_tkeep)
    );

    // ---------------------------------------------------------------------
    // Scoreboard: ring buffer of expected beats
    // ---------------------------------------------------------------------
    localparam int QCAP = 1 << 16;
    logic [31:0] exp_data [0:QCAP-1];
    logic [5:0]  exp_user [0:QCAP-1];
    logic        exp_last [0:QCAP-1];
    int          q_wr = 0, q_rd = 0;

    int unsigned beats_seen  = 0;
    int unsigned recs_tf     = 0;
    int unsigned recs_nontf  = 0;
    int unsigned errors      = 0;
    bit          driver_done = 0;

    function automatic bit fmt_is_int(input logic [4:0] f); return f[4]; endfunction

    task automatic expect_record(input logic [NUM_LANES-1:0][31:0] w,
                                 input logic [4:0] fmt, input logic [5:0] presc,
                                 input bit is_tf);
        logic [33:0] c;
        if (!is_tf) begin recs_nontf++; return; end
        recs_tf++;
        for (int k = 0; k < NUM_LANES; k++) begin
            c = conv_word(w[k], fmt_is_int(fmt), presc, 1'b0);   // RNE golden
            exp_data[q_wr] = c[31:0];
            exp_user[q_wr] = {c[33], c[32], 4'(k)};              // {nan, ovf, lane}
            exp_last[q_wr] = (k == NUM_LANES-1);
            q_wr = (q_wr + 1) % QCAP;
        end
    endtask

    // ---------------------------------------------------------------------
    // result_if driver
    // ---------------------------------------------------------------------
    task automatic drive_record(input logic [NUM_LANES-1:0][31:0] w,
                                input logic [4:0] fmt, input logic [5:0] presc,
                                input bit is_tf);
        @(negedge clk);
        rif.valid     = 1'b1;
        rif.data.hdr  = $urandom;
        rif.data.data = w;
        rif_is_tf     = is_tf;
        rif_fmt_d     = fmt;
        int_prescale  = presc;
        // hold valid until a posedge where the shim asserts ready (== accepted)
        forever begin
            @(posedge clk);
            if (rif.ready) break;
        end
        @(negedge clk);
        rif.valid = 1'b0;
        rif_is_tf = 1'b0;
        repeat ($urandom_range(0, 3)) @(negedge clk);   // random gap
    endtask

    // build a word set that stresses the converter corners + random
    function automatic logic [31:0] rand_word(input bit is_int);
        int pick;
        if (is_int) begin
            pick = $urandom_range(0, 5);
            case (pick)
                0: return 32'h0000_0000;
                1: return 32'h0000_0001;
                2: return 32'hFFFF_FFFF;
                3: return 32'h7FFF_FFFF;
                4: return 32'h8000_0000;
                default: return $urandom;
            endcase
        end else begin
            pick = $urandom_range(0, 7);
            case (pick)
                0: return 32'h0000_0000;                 // +0
                1: return 32'h3F80_0000;                 // +1.0
                2: return 32'hBF80_0000;                 // -1.0
                3: return 32'h7F80_0000;                 // +Inf  -> nan flag
                4: return 32'h7FC0_0000;                 // qNaN  -> nan flag
                5: return 32'h4880_0000;                 // e=145 -> ovf flag
                6: return ($urandom & 32'h807F_FFFF) | (32'($urandom_range(110,140)) << 23);
                default: return $urandom;
            endcase
        end
    endfunction

    initial begin : DRIVER
        logic [NUM_LANES-1:0][31:0] w;
        logic [4:0] fmt;
        logic [5:0] presc;
        bit is_tf, is_int;

        rif.valid = 0; rif_is_tf = 0; rif_fmt_d = 0; int_prescale = 0;
        repeat (8) @(negedge clk);
        reset = 0;
        repeat (4) @(negedge clk);

        for (int r = 0; r < N_RECORDS; r++) begin
            is_int = $urandom_range(0, 1);
            fmt    = is_int ? 5'h11 : 5'h04;             // I8 vs FP8 (only bit4 matters)
            presc  = is_int ? 6'($urandom_range(0, 30)) : 6'd0;
            is_tf  = ($urandom_range(0, 3) != 0);        // ~75% tile-final
            for (int k = 0; k < NUM_LANES; k++) w[k] = rand_word(is_int);
            expect_record(w, fmt, presc, is_tf);
            drive_record (w, fmt, presc, is_tf);
        end

        // drain
        driver_done = 1;
        repeat (NUM_LANES*8 + 200) @(negedge clk);

        if (q_rd != q_wr) begin
            $display("FAIL: %0d expected beats never arrived", (q_wr - q_rd + QCAP) % QCAP);
            errors++;
        end
        $display("----------------------------------------------------------------");
        $display(" records: tile-final=%0d  non-final=%0d", recs_tf, recs_nontf);
        $display(" beats seen=%0d  expected=%0d  errors=%0d",
                 beats_seen, recs_tf*NUM_LANES, errors);
        if (errors != 0 || beats_seen != recs_tf*NUM_LANES)
            $fatal(1, "full-shim testbench FAILED");
        $display(" PASS: shim framing / ordering / backpressure / drop-non-final OK");
        $finish;
    end

    // ---------------------------------------------------------------------
    // M_AXIS_CS sink — random backpressure + per-beat check
    // ---------------------------------------------------------------------
    initial axi_tready = 0;
    always @(negedge clk) axi_tready <= (reset) ? 1'b0 : ($urandom_range(0, 3) != 0);

    always @(posedge clk) if (!reset) begin
        if (axi_tvalid && axi_tready) begin
            logic [31:0] ed; logic [5:0] eu; logic el;
            beats_seen++;
            if (q_rd == q_wr) begin
                $display("[%0t] FAIL: unexpected M_AXIS beat tdata=%08h tuser=%02h tlast=%0b",
                         $time, axi_tdata, axi_tuser, axi_tlast);
                errors++;
            end else begin
                ed = exp_data[q_rd]; eu = exp_user[q_rd]; el = exp_last[q_rd];
                q_rd = (q_rd + 1) % QCAP;
                if (axi_tdata !== ed) begin
                    $display("[%0t] FAIL tdata: got %08h exp %08h (user %02h)", $time, axi_tdata, ed, eu);
                    errors++;
                end
                if (axi_tuser !== eu) begin
                    $display("[%0t] FAIL tuser: got %02h exp %02h (tdata %08h)", $time, axi_tuser, eu, axi_tdata);
                    errors++;
                end
                if (axi_tlast !== el) begin
                    $display("[%0t] FAIL tlast: got %0b exp %0b (user %02h)", $time, axi_tlast, el, eu);
                    errors++;
                end
            end
            if (axi_tid !== CFG_TID) begin
                $display("[%0t] FAIL tid: got %h exp %h", $time, axi_tid, CFG_TID); errors++;
            end
            if (axi_tkeep !== 4'hF) begin
                $display("[%0t] FAIL tkeep: got %h", $time, axi_tkeep); errors++;
            end
        end
    end

    // ---------------------------------------------------------------------
    // result_if.ready must be low while a record is serialising
    // (after an accepted tile-final beat, expect NUM_LANES cycles of ready==0)
    // ---------------------------------------------------------------------
    int load_guard = 0;
    always @(posedge clk) if (!reset) begin
        if (rif.valid && rif.ready && rif_is_tf) load_guard <= NUM_LANES;
        else if (load_guard > 0) begin
            if (rif.ready !== 1'b0) begin
                $display("[%0t] FAIL: result_if.ready high mid-record (%0d left)", $time, load_guard);
                errors++;
            end
            load_guard <= load_guard - 1;
        end
    end

    // watchdog
    initial begin
        #(1ms);
        $display("FAIL: watchdog timeout"); $fatal(1);
    end

endmodule
