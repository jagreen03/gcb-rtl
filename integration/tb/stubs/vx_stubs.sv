// Minimal Vortex stubs — STANDALONE SIM OF THE SHIM ONLY.
// Real integration uses the Vortex tree. Enough here to elaborate
// VX_tcu_shim_q1714.sv and exercise its I/O in tb_VX_tcu_shim_q1714.sv.
//
// NOTE: Icarus 11 has no `parameter type`, so VX_result_if here is fixed to
// the stub `tcu_result_t` (the real Vortex interface is type-parameterised).

// ---------------------------------------------------------------------------
package VX_gpu_pkg;
    localparam VX_GPU_PKG_STUB = 1;   // the shim references nothing from here
endpackage

// ---------------------------------------------------------------------------
package VX_tcu_pkg;
    // Only used for the shim's default NUM_LANES; the TB overrides NUM_LANES.
    localparam TCU_TC_M = 2;
    localparam TCU_TC_N = 2;

    // Stub result payload (real: DECL_EXECUTE_T(tcu, NUM_TCU_LANES)).
    localparam NUM_TCU_LANES = 8;
    typedef struct packed {
        logic [7:0]                     hdr;    // stand-in for tcu_header_t
        logic [NUM_TCU_LANES-1:0][31:0] data;   // per-lane resolved words
    } tcu_result_t;
endpackage

// ---------------------------------------------------------------------------
interface VX_result_if import VX_tcu_pkg::*; ();
    logic        valid;
    tcu_result_t data;
    logic        ready;
    modport master (output valid, output data, input  ready);
    modport slave  (input  valid, input  data, output ready);
endinterface

// ---------------------------------------------------------------------------
// Behavioural first-word-fall-through synchronous FIFO. OUT_REG ignored
// (data_out is combinational off the read pointer) — the shim's sink path
// does not depend on the extra output register for correctness.
module VX_fifo_queue #(
    parameter DATAW     = 1,
    parameter DEPTH     = 2,
    parameter ALM_FULL  = (DEPTH - 1),
    parameter ALM_EMPTY = 1,
    parameter OUT_REG   = 0,
    parameter LUTRAM    = 0,
    parameter SIZEW     = $clog2(DEPTH + 1)
) (
    input  wire             clk,
    input  wire             reset,
    input  wire             push,
    input  wire             pop,
    input  wire [DATAW-1:0] data_in,
    output wire [DATAW-1:0] data_out,
    output wire             empty,
    output wire             alm_empty,
    output wire             full,
    output wire             alm_full,
    output wire [SIZEW-1:0] size
);
    localparam AW = (DEPTH <= 1) ? 1 : $clog2(DEPTH);
    logic [DATAW-1:0] mem [0:DEPTH-1];
    logic [AW:0] wr_ptr, rd_ptr;
    wire  [AW:0] cnt = wr_ptr - rd_ptr;

    assign empty     = (cnt == 0);
    assign full      = (cnt == DEPTH);
    assign alm_empty = (cnt <= ALM_EMPTY);
    assign alm_full  = (cnt >= ALM_FULL);
    assign size      = cnt[SIZEW-1:0];
    assign data_out  = mem[rd_ptr[AW-1:0]];

    always @(posedge clk) begin
        if (reset) begin
            wr_ptr <= '0;
            rd_ptr <= '0;
        end else begin
            if (push && !full)  begin mem[wr_ptr[AW-1:0]] <= data_in; wr_ptr <= wr_ptr + 1'b1; end
            if (pop  && !empty)       rd_ptr <= rd_ptr + 1'b1;
        end
    end

    always @(posedge clk) if (!reset) begin
        if (push && full  && !pop) begin $display("[%0t] STUB FIFO overflow",  $time); $fatal(1); end
        if (pop  && empty)         begin $display("[%0t] STUB FIFO underflow", $time); $fatal(1); end
    end
endmodule
