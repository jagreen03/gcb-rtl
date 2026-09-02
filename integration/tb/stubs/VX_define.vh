// Minimal VX_define.vh — STANDALONE SIM OF THE SHIM ONLY (Verilator).
// Real integration uses the Vortex tree's VX_define.vh. These stubs cover only
// the macros VX_tcu_shim_q1714.sv references.
`ifndef VX_DEFINE_VH
`define VX_DEFINE_VH

`define STRING            string
`define CLOG2(x)          ($clog2(x))
`define UP(x)             (((x) < 1) ? 1 : (x))
`define UNUSED_SPARAM(x)
`define UNUSED_VAR(x)
`define UNUSED_PIN(x)     .x()
`define STATIC_ASSERT(c, m)

// active-high `reset` is in scope wherever the shim uses this
`define RUNTIME_ASSERT(c, m)                                                   \
    always @(posedge clk) if ((reset === 1'b0) && !(c)) begin                  \
        $display("[%0t] RUNTIME_ASSERT FAIL: %s", $time, $sformatf m);         \
        $fatal(1);                                                            \
    end

`endif
