// =============================================================================
// tb_ss_calib.sv  --  bit-exact check of greencoyote_ss_calib against the
// Python fixed-point golden model (sim/golden_ss_readout.py).
//
// Reads sim_out/ss_calib_vectors.txt : "# header" then rows
//   code(dec)  C2(hex8)  C1(hex8)  C0(hex8)  xhat(hex5)
// streams each through the 3-stage pipe, compares x_hat bit-for-bit.
// PASS  <=>  every checked row matches AND >= MIN_ROWS rows checked.
// (written for Icarus Verilog 11 -g2012: no queues, no string ops)
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_ss_calib;
    localparam integer CW        = 14;
    localparam integer COEF_BITS = 32;
    localparam integer XHAT_BITS = 18;
    localparam integer MIN_ROWS  = 10000;
    localparam integer MAXV      = 20000;

    reg clk = 1'b0, rst_n = 1'b0;
    always #0.5 clk = ~clk;

    reg                        in_valid;
    reg  [CW-1:0]              code;
    reg  signed [COEF_BITS-1:0] c2, c1, c0;
    wire                       out_valid;
    wire [XHAT_BITS-1:0]       x_hat;

    greencoyote_ss_calib dut (
        .clk(clk), .rst_n(rst_n), .in_valid(in_valid),
        .code(code), .c2(c2), .c1(c1), .c0(c0),
        .out_valid(out_valid), .x_hat(x_hat));

    // ---- vector store, loaded by $readmemh-style manual parse --------------
    integer      v_code   [0:MAXV-1];
    reg [31:0]   v_c2      [0:MAXV-1];
    reg [31:0]   v_c1      [0:MAXV-1];
    reg [31:0]   v_c0      [0:MAXV-1];
    reg [XHAT_BITS-1:0] v_xh [0:MAXV-1];

    integer nvec, fd, rc, k;
    integer ic; reg [31:0] h2, h1, h0, hx;
    reg [1023:0] dummy;

    integer feed_i, exp_wr, exp_rd, nchk, nfail;
    reg [XHAT_BITS-1:0] exp_mem [0:63];   // small ring, pipe latency 3

    initial begin
        in_valid = 1'b0; code = '0; c2 = '0; c1 = '0; c0 = '0;
        nvec = 0; nchk = 0; nfail = 0; exp_wr = 0; exp_rd = 0;

        fd = $fopen("sim_out/ss_calib_vectors.txt", "r");
        if (fd == 0) begin $display("FAIL: cannot open vector file"); $finish; end
        rc = $fgets(dummy, fd);                       // header line
        while (!$feof(fd) && nvec < MAXV) begin
            rc = $fscanf(fd, "%d %h %h %h %h\n", ic, h2, h1, h0, hx);
            if (rc == 5) begin
                v_code[nvec] = ic;
                v_c2[nvec]   = h2;
                v_c1[nvec]   = h1;
                v_c0[nvec]   = h0;
                v_xh[nvec]   = hx[XHAT_BITS-1:0];
                nvec = nvec + 1;
            end
        end
        $fclose(fd);
        $display("tb_ss_calib: loaded %0d vectors", nvec);

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        for (feed_i = 0; feed_i < nvec; feed_i = feed_i + 1) begin
            @(negedge clk);
            in_valid = 1'b1;
            code = v_code[feed_i][CW-1:0];
            c2   = v_c2[feed_i];
            c1   = v_c1[feed_i];
            c0   = v_c0[feed_i];
            exp_mem[exp_wr[5:0]] = v_xh[feed_i];
            exp_wr = exp_wr + 1;
        end
        @(negedge clk);
        in_valid = 1'b0;
        repeat (8) @(posedge clk);

        if (nfail != 0)
            $display("=== tb_ss_calib: %0d/%0d MISMATCH -- FAIL ===", nfail, nchk);
        else if (nchk < MIN_ROWS)
            $display("=== tb_ss_calib: only %0d rows checked (< %0d) -- FAIL ===",
                     nchk, MIN_ROWS);
        else
            $display("=== tb_ss_calib: ALL %0d CHECKS PASS ===", nchk);
        $finish;
    end

    // consume + compare
    reg [XHAT_BITS-1:0] e;
    always @(posedge clk) begin
        if (rst_n && out_valid) begin
            e = exp_mem[exp_rd[5:0]];
            exp_rd = exp_rd + 1;
            nchk = nchk + 1;
            if (x_hat !== e) begin
                nfail = nfail + 1;
                if (nfail <= 20)
                    $display("MISMATCH #%0d: got %05h exp %05h  (code=%0d c2=%08h c1=%08h c0=%08h)",
                             nchk, x_hat, e, v_code[nchk-1], v_c2[nchk-1], v_c1[nchk-1], v_c0[nchk-1]);
            end
        end
    end

    initial begin
        #4_000_000;
        $display("=== tb_ss_calib: TIMEOUT -- FAIL ===");
        $finish;
    end
endmodule

`default_nettype wire
