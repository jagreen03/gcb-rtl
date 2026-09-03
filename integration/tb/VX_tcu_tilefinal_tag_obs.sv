// =============================================================================
// GreenCoyote-Bay <-> Vortex 3.0 - tile-final tag observer shim
// =============================================================================
// Wraps the real VX_tcu_tilefinal_tag.sv (unchanged) so it can be `bind`-ed into
// VX_tcu_core as an observer: the tag wrapper needs four SV interface ports and
// drives handshake wires on them, which multi-drives if the interfaces are the
// core's own. This shim gives the tag wrapper private VX_execute_if /
// VX_result_if instances driven from scalar snoop taps, so the tag wrapper runs
// in its natural passthrough mode against a faithful copy of the core's
// execute_if / result_if activity and produces a live is_tile_final.
//
//   bind VX_tcu_core VX_tcu_tilefinal_tag_obs u_tf_tag_obs (
//     .clk(clk), .reset(reset),
//     .exe_valid(execute_if.valid), .exe_ready(execute_if.ready),
//     .exe_data (execute_if.data),
//     .res_valid(result_if.valid),  .res_ready(result_if.ready),
//     .res_data (result_if.data),
//     .is_tile_final(/* read by the SVA bind */)
//   );
// =============================================================================

`include "VX_define.vh"

module VX_tcu_tilefinal_tag_obs import VX_gpu_pkg::*, VX_tcu_pkg::*; (
    input  wire          clk,
    input  wire          reset,
    input  wire          exe_valid,
    input  wire          exe_ready,
    input  tcu_execute_t exe_data,
    input  wire          res_valid,
    input  wire          res_ready,
    input  tcu_result_t  res_data,
    output wire          is_tile_final
);
    VX_execute_if #(.data_t (tcu_execute_t)) exe_ext();
    VX_execute_if #(.data_t (tcu_execute_t)) exe_core();
    VX_result_if  #(.data_t (tcu_result_t))  res_ext();
    VX_result_if  #(.data_t (tcu_result_t))  res_core();

    // drive the tag wrapper's input sides from the snoop taps
    assign exe_ext.valid  = exe_valid;
    assign exe_ext.data   = exe_data;
    assign res_core.valid = res_valid;
    assign res_core.data  = res_data;
    // close the passthrough loop so exe_fire / res_fire inside the tag wrapper
    // reduce to (exe_valid && exe_ready) / (res_valid && res_ready)
    assign exe_core.ready = exe_ready;   // tag: exe_ext.ready  = exe_core.ready
    assign res_ext.ready  = res_ready;   // tag: res_core.ready = res_ext.ready

    VX_tcu_tilefinal_tag #(
        .INSTANCE_ID ("tf_tag_obs")
    ) u_tag (
        .clk             (clk),
        .reset           (reset),
        .execute_if      (exe_ext),
        .result_if       (res_ext),
        .is_tile_final   (is_tile_final),
        .fmt_d_out       (),
        .execute_core_if (exe_core),
        .result_core_if  (res_core)
    );

endmodule
