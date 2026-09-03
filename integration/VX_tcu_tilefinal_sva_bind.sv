// =============================================================================
// GreenCoyote-Bay <-> Vortex 3.0 - tile-final SVA + tag binds
// =============================================================================
// Binds two observers into every VX_tcu_core instance. Kept out of the vortex
// clone (added to the Verilator source list by integration/tb/run_tilefinal_check.sh).
//
//   u_tf_tag_obs     - VX_tcu_tilefinal_tag_obs: the real VX_tcu_tilefinal_tag.sv
//                      wrapped in an observer shim, fed from execute_if /
//                      result_if snoop taps. Produces a live is_tile_final
//                      aligned to result_if.valid.
//   u_tilefinal_sva  - VX_tcu_tilefinal_sva (A1..A5). Reaches the core's own
//                      predicates (execute_fire, fedp_enqueue, fedp_result_fire,
//                      is_wgmma, step_m/n/k), result_if.data.header.eop, and the
//                      tag observer's is_tile_final so A3/A5 evaluate.
// =============================================================================

bind VX_tcu_core VX_tcu_tilefinal_tag_obs u_tf_tag_obs (
    .clk           (clk),
    .reset         (reset),
    .exe_valid     (execute_if.valid),
    .exe_ready     (execute_if.ready),
    .exe_data      (execute_if.data),
    .res_valid     (result_if.valid),
    .res_ready     (result_if.ready),
    .res_data      (result_if.data),
    .is_tile_final (/* read by u_tilefinal_sva below */)
);

bind VX_tcu_core VX_tcu_tilefinal_sva #(
    .M_STEPS    (VX_tcu_pkg::TCU_M_STEPS),
    .N_STEPS    (VX_tcu_pkg::TCU_N_STEPS),
    .K_STEPS    (VX_tcu_pkg::TCU_K_STEPS),
    .WG_K_STEPS (VX_tcu_pkg::TCU_WG_K_STEPS),
    .UOPS       (VX_tcu_pkg::TCU_UOPS),
    .TC_K       (VX_tcu_pkg::TCU_TC_K),
    .TILE_K     (VX_tcu_pkg::TCU_TILE_K)
) u_tilefinal_sva (
    .clk              (clk),
    .reset            (reset),
    .execute_fire     (execute_fire),
    .fedp_enqueue     (fedp_enqueue),
    .fedp_result_fire (fedp_result_fire),
`ifdef VX_CFG_TCU_WGMMA_ENABLE
    .is_wgmma         (is_wgmma),
`else
    .is_wgmma         (1'b0),                       // is_wgmma is ifdef'd out in the core
`endif
    .step_m           (step_m),
    .step_n           (step_n),
    .step_k           (step_k),
    .is_tile_final    (u_tf_tag_obs.is_tile_final),
    .header_eop       (result_if.data.header.eop)
);
