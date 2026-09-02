// =============================================================================
// tb_VX_tcu_q1714_convert.sv — bit-exact test for VX_tcu_q1714_convert_pkg
// Project: GreenCoyote-Bay / ODIN_Bridge
// =============================================================================
// Standalone, dependency-free. Verifies conv_word() (fp32/int32 -> Q17.14,
// used by VX_tcu_shim_q1714) bit-for-bit against an INDEPENDENT reference
// model built from real / longint arithmetic — no shared code with the DUT.
//
//   iverilog -g2012 -o sim_out/convtb ../VX_tcu_q1714_convert_pkg.sv \
//            tb_VX_tcu_q1714_convert.sv && vvp sim_out/convtb
//
// (see run_convert_tb.sh). Requires Icarus Verilog >= 11 ($urandom_range).
// =============================================================================

`timescale 1ns/1ps

module tb_VX_tcu_q1714_convert;
    import VX_tcu_q1714_convert_pkg::*;

    int unsigned checks = 0;
    int unsigned errors = 0;

    // =========================================================================
    // Reference: fp32 -> Q17.14  (real arithmetic; exact for the Q17.14 range)
    // =========================================================================
    function automatic real pow2r(input int k);
        real r; int i;
        begin
            r = 1.0;
            if (k >= 0) for (i = 0; i <  k; i++) r = r * 2.0;
            else        for (i = 0; i < -k; i++) r = r / 2.0;
            pow2r = r;
        end
    endfunction

    // round-half-to-even of a real, staying in the real domain (doubles hold any
    // fp32*2^14 magnitude exactly, so no overflow); trunc==1 -> floor.
    function automatic real rne_real(input real x, input bit trunc);
        real fl, frac, half_even;
        begin
            fl = $floor(x);
            if (trunc) begin
                rne_real = fl;
            end else begin
                frac = x - fl;
                if      (frac < 0.5) rne_real = fl;
                else if (frac > 0.5) rne_real = fl + 1.0;
                else begin                              // exact tie -> to even
                    half_even = fl - 2.0 * $floor(fl / 2.0);   // 0.0 if fl even
                    rne_real  = (half_even == 0.0) ? fl : fl + 1.0;
                end
            end
        end
    endfunction

    function automatic logic [33:0] ref_fp(input logic [31:0] w, input bit trunc);
        logic s; logic [7:0] e; logic [22:0] m;
        real val, scaled, rr;
        begin
            s = w[31]; e = w[30:23]; m = w[22:0];
            if (e == 8'hFF) return {1'b1, 1'b0, (s ? Q17_14_MIN : Q17_14_MAX)};
            if (e == 8'h00) return {1'b0, 1'b0, 32'd0};

            val    = 1.0 + ($itor(m) / 8388608.0);        // 1.m
            val    = val * pow2r(int'(e) - 127);          // * 2^(e-127)
            if (s) val = -val;
            scaled = val * 16384.0;                       // * 2^14  (exact)

            rr = rne_real(scaled, trunc);                 // real-domain round
            if (rr >  2147483647.0)  return {1'b0, 1'b1, Q17_14_MAX};
            if (rr < -2147483648.0)  return {1'b0, 1'b1, Q17_14_MIN};
            return {1'b0, 1'b0, $rtoi(rr)};               // now safely in int32 range
        end
    endfunction

    // =========================================================================
    // Reference: int32 -> Q17.14
    // =========================================================================
    function automatic longint rne_shift(input longint v, input int r, input bit trunc);
        longint fl, mask; logic guard, sticky, lsb;
        begin
            fl = v >>> r;                                 // arithmetic -> floor
            if (trunc) return fl;
            mask   = (r >= 1) ? ((64'sd1 <<< (r-1)) - 64'sd1) : 64'sd0;
            guard  = (r >= 1) ? v[r-1] : 1'b0;
            sticky = ((v & mask) != 0);
            lsb    = v[r];
            return fl + ((guard && (sticky || lsb)) ? 64'sd1 : 64'sd0);
        end
    endfunction

    function automatic logic [33:0] ref_int(input logic [31:0] w,
                                             input logic [5:0]  presc,
                                             input bit          trunc);
        longint iv, res; int net;
        begin
            iv  = longint'($signed(w));
            net = 14 - int'(presc);
            if (net >= 0) res = iv <<< net;
            else          res = rne_shift(iv, -net, trunc);
            if (res >  64'sd2147483647)  return {1'b0, 1'b1, Q17_14_MAX};
            if (res < -64'sd2147483648)  return {1'b0, 1'b1, Q17_14_MIN};
            return {1'b0, 1'b0, res[31:0]};
        end
    endfunction

    // =========================================================================
    // Checkers
    // =========================================================================
    task automatic chk_fp(input logic [31:0] w, input bit trunc, input string tag = "");
        logic [33:0] d, r;
        begin
            d = conv_word(w, 1'b0, 6'd0, trunc);
            r = ref_fp(w, trunc);
            checks++;
            if (d !== r) begin
                errors++;
                $display("FAIL fp  [%s] w=%08h trunc=%0b | DUT nan=%0b ovf=%0b q=%08h | REF nan=%0b ovf=%0b q=%08h",
                         tag, w, trunc, d[33], d[32], d[31:0], r[33], r[32], r[31:0]);
            end
        end
    endtask

    task automatic chk_int(input logic [31:0] w, input logic [5:0] presc,
                           input bit trunc, input string tag = "");
        logic [33:0] d, r;
        begin
            d = conv_word(w, 1'b1, presc, trunc);
            r = ref_int(w, presc, trunc);
            checks++;
            if (d !== r) begin
                errors++;
                $display("FAIL int [%s] w=%08h presc=%0d trunc=%0b | DUT ovf=%0b q=%08h | REF ovf=%0b q=%08h",
                         tag, w, presc, trunc, d[32], d[31:0], r[32], r[31:0]);
            end
        end
    endtask

    // =========================================================================
    initial begin
        logic [31:0] w; logic [5:0] pp; int i; bit t;

        // ---- directed fp32 -------------------------------------------------
        for (int ti = 0; ti < 2; ti++) begin
            t = ti[0];
            chk_fp(32'h0000_0000, t, "+0");
            chk_fp(32'h8000_0000, t, "-0");
            chk_fp(32'h3F80_0000, t, "+1.0");
            chk_fp(32'hBF80_0000, t, "-1.0");
            chk_fp(32'h3F00_0000, t, "+0.5");
            chk_fp(32'h3DCC_CCCD, t, "+0.1");
            chk_fp(32'h4048_F5C3, t, "+3.14");
            chk_fp(32'h4780_0000, t, "+65536");
            chk_fp(32'h4700_0000, t, "+32768");
            chk_fp(32'hC700_0000, t, "-32768");
            chk_fp(32'h7F7F_FFFF, t, "+FLT_MAX -> ovf");
            chk_fp(32'hFF7F_FFFF, t, "-FLT_MAX -> ovf");
            chk_fp(32'h7F80_0000, t, "+Inf");
            chk_fp(32'hFF80_0000, t, "-Inf");
            chk_fp(32'h7FC0_0000, t, "qNaN");
            chk_fp(32'h7F80_0001, t, "sNaN");
            chk_fp(32'h0000_0001, t, "min subnormal");
            chk_fp(32'h007F_FFFF, t, "max subnormal");
            chk_fp(32'h0080_0000, t, "min normal -> 0");
            chk_fp(32'h3800_0000, t, "2^-15 -> 0.5 LSB tie");
            chk_fp(32'h3880_0000, t, "2^-14 -> 1 LSB");
            chk_fp(32'h38C0_0000, t, "1.5*2^-14 -> 1.5 LSB tie");
            chk_fp(32'h4780_0001, t, "e=143 m=1");
            chk_fp(32'h4800_0000, t, "e=144 -> ovf (kexp>=8)");
            chk_fp(32'h46FF_FFFF, t, "e=141 max mantissa");
            chk_fp(32'h34000000, t, "2^-23 -> far below LSB");
        end

        // ---- randomized fp32 --------------------------------------------
        for (i = 0; i < 300000; i++) begin
            w = $random;
            chk_fp(w, 1'b0); chk_fp(w, 1'b1);
        end
        // biased into the decision-heavy exponent window e in [100..150]
        for (i = 0; i < 300000; i++) begin
            w = ($random & 32'h807F_FFFF) | (32'($urandom_range(100, 150)) << 23);
            chk_fp(w, 1'b0); chk_fp(w, 1'b1);
        end

        // ---- directed int32 -------------------------------------------
        for (int ti = 0; ti < 2; ti++) begin
            t = ti[0];
            chk_int(32'h0000_0000, 6'd0,  t, "0");
            chk_int(32'h0000_0001, 6'd0,  t, "+1 <<14");
            chk_int(32'hFFFF_FFFF, 6'd0,  t, "-1 <<14");
            chk_int(32'h0000_2000, 6'd0,  t, "8192 <<14 -> ovf");
            chk_int(32'h7FFF_FFFF, 6'd0,  t, "INT_MAX -> ovf");
            chk_int(32'h8000_0000, 6'd0,  t, "INT_MIN -> ovf");
            chk_int(32'h0002_0000, 6'd14, t, "131072 net0");
            chk_int(32'h0001_0000, 6'd20, t, "65536 >>6");
            chk_int(32'hFFFF_0000, 6'd20, t, "-65536 >>6");
            chk_int(32'h0000_0003, 6'd15, t, "3 >>1 tie");
            chk_int(32'h0000_0001, 6'd15, t, "1 >>1 -> 0");
            chk_int(32'h0000_0006, 6'd16, t, "6 >>2 tie -> even");
            chk_int(32'h0000_000A, 6'd16, t, "10 >>2 tie -> even");
            chk_int(32'h7FFF_FFFF, 6'd20, t, "INT_MAX >>6");
            chk_int(32'h8000_0000, 6'd20, t, "INT_MIN >>6");
            chk_int(32'h8000_0000, 6'd40, t, "INT_MIN >>26");
        end

        // ---- randomized int32 x prescale --------------------------
        for (i = 0; i < 300000; i++) begin
            w  = $random;
            pp = 6'($urandom_range(0, 40));
            chk_int(w, pp, 1'b0); chk_int(w, pp, 1'b1);
        end

        $display("----------------------------------------------------------------");
        $display(" checks=%0d  errors=%0d", checks, errors);
        if (errors != 0) $fatal(1, "bit-exact conversion mismatch");
        $display(" PASS: conv_word is bit-exact vs the independent reference");
        $finish;
    end
endmodule
