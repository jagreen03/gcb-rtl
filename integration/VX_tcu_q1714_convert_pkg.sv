// =============================================================================
// GreenCoyote-Bay — Ten-Four writeback -> Q17.14 conversion (pure function)
// Project: ODIN_Bridge / Cascaded Optical Reduction Fabric
// =============================================================================
// The bit-exact arithmetic of VX_tcu_shim_q1714, factored out as a dependency-
// free SystemVerilog package so it is one source of truth and unit-testable
// without the Vortex build (no VX_define.vh, no VX_gpu_pkg).
//
//   float  (is_int==0): w is IEEE-754 binary32.
//     q = round( w * 2^14 ), saturating to the 32-bit signed range
//         (= Q17.14 full scale). e==0 -> 0. e==255 -> saturate + nan.
//   int    (is_int==1): w is int32.
//     q = sat32( round( $signed(w) <<< (14 - presc) ) ).
//
// round = round-to-nearest-even, or floor (toward -inf) when round_trunc==1.
// Returns {nan, ovf, q[31:0]}.  See gcb-spec/carry_save_streaming_contract.md
// §4.2 and gcb-spec/vortex_integration_notes.md §5.
// =============================================================================

package VX_tcu_q1714_convert_pkg;

    localparam logic [31:0] Q17_14_MAX = 32'h7FFF_FFFF;   //  +131071.999938...
    localparam logic [31:0] Q17_14_MIN = 32'h8000_0000;   //  -131072.0

    // Magnitude-domain rounding decision (the fp path holds |x| in mant24 and
    // negates afterwards, so "floor" = round the magnitude AWAY from zero when
    // the value is negative and any bits were dropped).
    //   round_trunc==0 : round-to-nearest-even
    //   round_trunc==1 : floor (toward -inf)
    // `sign` is the sign of the value; pass 1'b0 on paths whose shift already
    // floors in two's complement (the int path), so trunc adds nothing there.
    function automatic logic round_up_mag (input logic guard,
                                            input logic sticky,
                                            input logic lsb,
                                            input logic sign,
                                            input logic round_trunc);
        round_up_mag = round_trunc ? (sign && (guard || sticky))
                                   : (guard && (sticky || lsb));
    endfunction

    // {nan, ovf, q[31:0]}
    function automatic logic [33:0] conv_word (input logic [31:0] w,
                                               input logic        is_int,
                                               input logic [5:0]  presc,
                                               input logic         round_trunc);
        logic        s;
        logic [7:0]  e;
        logic [22:0] man;
        logic [23:0] mant24;
        logic signed [8:0] kexp;              // e - 136
        logic [63:0] wide;
        logic [31:0] mag;
        logic        guard, sticky, ovf, nan;
        logic [31:0] q;
        logic signed [7:0]  ns;               // net left shift, int path
        logic signed [63:0] iv_ext;
        integer r;
        begin
            ovf = 1'b0; nan = 1'b0; q = 32'd0;
            mant24 = '0; kexp = '0; wide = '0; mag = '0;
            guard = 1'b0; sticky = 1'b0; ns = '0; iv_ext = '0; r = 0;

            if (is_int) begin
                // ---- int32 -> Q17.14 -------------------------------------
                ns     = 8'sd14 - $signed({2'b00, presc});      // 14 - presc
                iv_ext = {{32{w[31]}}, w};                       // sign-extend

                if (ns >= 0) begin
                    wide = $unsigned(iv_ext <<< ns);
                    if ($signed(iv_ext <<< ns) > $signed(64'sd2147483647)) begin
                        q = Q17_14_MAX; ovf = 1'b1;
                    end else if ($signed(iv_ext <<< ns) < -$signed(64'sd2147483648)) begin
                        q = Q17_14_MIN; ovf = 1'b1;
                    end else begin
                        q = wide[31:0];
                    end
                end else begin
                    r      = -ns;
                    guard  = (r >= 1 && r <= 63) ? iv_ext[r-1] : 1'b0;
                    sticky = ((iv_ext & ((64'sd1 <<< (r-1)) - 64'sd1)) != 0);
                    q      = $signed(iv_ext >>> r)
                             + (round_up_mag(guard, sticky, iv_ext[r], 1'b0, round_trunc) ? 32'sd1 : 32'sd0);
                end
            end else begin
                // ---- fp32 -> Q17.14 ------------------------------------
                s   = w[31];
                e   = w[30:23];
                man = w[22:0];

                if (e == 8'hFF) begin
                    nan = 1'b1;
                    q   = s ? Q17_14_MIN : Q17_14_MAX;          // saturate; pilot drops
                end else if (e == 8'h00) begin
                    q   = 32'd0;                                // zero / subnormal << LSB
                end else begin
                    mant24 = {1'b1, man};                       // 1.man scaled by 2^23
                    kexp   = $signed({1'b0, e}) - 9'sd136;      // value*2^14 = mant24 * 2^kexp

                    if (kexp >= 0) begin
                        if (kexp >= 8) begin
                            q = s ? Q17_14_MIN : Q17_14_MAX; ovf = 1'b1;
                        end else begin
                            wide = ({40'd0, mant24} << kexp[3:0]);
                            if (wide > {32'd0, Q17_14_MAX}) begin
                                q = s ? Q17_14_MIN : Q17_14_MAX; ovf = 1'b1;
                            end else begin
                                mag = wide[31:0];
                                q   = s ? (~mag + 32'd1) : mag;
                            end
                        end
                    end else begin
                        r = -kexp;
                        if (r >= 24) begin
                            guard  = (r == 24) ? mant24[23] : 1'b0;
                            sticky = (r == 24) ? (mant24[22:0] != 0)
                                               : (mant24 != 0);
                            mag    = round_up_mag(guard, sticky, 1'b0, s, round_trunc) ? 32'd1 : 32'd0;
                        end else begin
                            guard  = mant24[r-1];
                            sticky = ((mant24 & ((24'd1 << (r-1)) - 24'd1)) != 0);
                            mag    = (mant24 >> r)
                                     + (round_up_mag(guard, sticky, mant24[r], s, round_trunc) ? 32'd1 : 32'd0);
                        end
                        q = s ? (~mag + 32'd1) : mag;
                    end
                end
            end

            conv_word = {nan, ovf, q};
        end
    endfunction

endpackage
