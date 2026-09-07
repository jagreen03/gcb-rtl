// =============================================================================
// greencoyote_ss_calib.sv
// Single-slope readout 3-point (quadratic) calibration back-end.
//
// Applies a per-channel quadratic  x_hat = C2*u^2 + C1*u + C0  to each raw TDC
// code, evaluated by Horner in fixed point.  The 3-point fit that produces
// {C2,C1,C0} from the three dummy-reference measurements is a firmware/host
// operation (see sim/golden_ss_readout.py :: fx_fit_3pt); this block only
// evaluates the polynomial.  Coefficients arrive per channel from the
// SS_CAL coefficient BRAM (greencoyote_pilot_regs).
//
// FIXED-POINT CONTRACT  (bit-exact to sim/golden_ss_readout.py :: fx_calib)
//   code     : CW=14-bit unsigned            {coarse[13:2], phase[1:0]}
//   C2,C1,C0 : signed 32-bit,  Q4.28
//   acc      : signed 48-bit,  Q4.28
//       acc = C2
//       acc = (acc * code) >>> 14  + C1        (add, then wrap to 48 b)
//       acc = (acc * code) >>> 14  + C0
//   x_hat    : unsigned 18-bit, Q2.16
//       t     = (acc + 2048) >>> 12            (round Q4.28 -> Q4.16)
//       x_hat = clamp(t, 0, 18'h3FFFF)
//
// 3-stage pipeline, one multiply per stage.  in_valid -> out_valid after 3
// clocks; the caller must hold {code,C2,C1,C0} for the cycle in_valid is high.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module greencoyote_ss_calib #(
    parameter int CW        = 14,
    parameter int QC        = 28,
    parameter int COEF_BITS = 32,
    parameter int ACC_BITS  = 48,
    parameter int XHAT_BITS  = 18
) (
    input  wire                          clk,
    input  wire                          rst_n,

    input  wire                          in_valid,
    input  wire [CW-1:0]                 code,
    input  wire signed [COEF_BITS-1:0]   c2,
    input  wire signed [COEF_BITS-1:0]   c1,
    input  wire signed [COEF_BITS-1:0]   c0,

    output logic                         out_valid,
    output logic [XHAT_BITS-1:0]         x_hat
);
    localparam int XHAT_MAX = (1 << XHAT_BITS) - 1;   // 18'h3FFFF

    // wide signed helpers
    // (acc * code) is (ACC_BITS) x (CW+1) signed -> keep full then >>> CW
    function automatic signed [ACC_BITS-1:0] mul_sra
        (input signed [ACC_BITS-1:0] a, input [CW-1:0] u);
        logic signed [ACC_BITS+CW:0] p;              // 48 + 14 + 1
        begin
            p = a * $signed({1'b0, u});              // signed * (positive)
            mul_sra = ACC_BITS'(p >>> CW);           // arithmetic, then wrap 48b
        end
    endfunction

    // ---- stage 1 : latch inputs, acc0 = C2 -----------------------------------
    logic                         v1;
    logic [CW-1:0]                 code1;
    logic signed [COEF_BITS-1:0]   c1_1, c0_1;
    logic signed [ACC_BITS-1:0]    acc1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v1 <= 1'b0; code1 <= '0; c1_1 <= '0; c0_1 <= '0; acc1 <= '0;
        end else begin
            v1    <= in_valid;
            code1 <= code;
            c1_1  <= c1;
            c0_1  <= c0;
            acc1  <= ACC_BITS'($signed(c2));         // sign-extend C2 -> 48b
        end
    end

    // ---- stage 2 : acc2 = (acc1 * code) >>> CW + C1 -------------------------
    logic                         v2;
    logic [CW-1:0]                 code2;
    logic signed [COEF_BITS-1:0]   c0_2;
    logic signed [ACC_BITS-1:0]    acc2;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v2 <= 1'b0; code2 <= '0; c0_2 <= '0; acc2 <= '0;
        end else begin
            v2    <= v1;
            code2 <= code1;
            c0_2  <= c0_1;
            acc2  <= mul_sra(acc1, code1) + ACC_BITS'($signed(c1_1));
        end
    end

    // ---- stage 3 : acc3 = (acc2 * code) >>> CW + C0 ; round + clamp ---------
    logic signed [ACC_BITS-1:0] acc3;
    logic signed [ACC_BITS-1:0] t3;

    always_comb begin
        acc3 = mul_sra(acc2, code2) + ACC_BITS'($signed(c0_2));
        t3   = (acc3 + ACC_BITS'(sd_2048())) >>> 12;   // round Q4.28 -> Q4.16
    end

    function automatic signed [ACC_BITS-1:0] sd_2048();
        sd_2048 = ACC_BITS'(48'sd2048);
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            x_hat     <= '0;
        end else begin
            out_valid <= v2;
            if (t3 < 0)
                x_hat <= '0;
            else if (t3 > XHAT_MAX)
                x_hat <= XHAT_BITS'(XHAT_MAX);
            else
                x_hat <= t3[XHAT_BITS-1:0];
        end
    end

endmodule

`default_nettype wire
