// =============================================================================
// GreenCoyote-Bay <-> Vortex 3.0 — tile-final SVA bind
// =============================================================================
// Binds VX_tcu_tilefinal_sva (A1..A5, vortex_integration_notes.md sec 8.4) into
// every VX_tcu_core instance. Kept in its own file so the vortex clone stays
// pristine — this file is added to the Verilator source list by
// integration/tb/run_tilefinal_check.sh, never copied into the vortex tree.
//
// The bind expression reaches VX_tcu_core's own internal predicates (execute_fire,
// fedp_enqueue, fedp_result_fire, is_wgmma, step_m/n/k) and the interface struct
// field execute_if.data.header.eop — which only elaborate correctly inside a real
// top (VX_tcu_unit_top), the reason this check runs as a full build rather than a
// standalone lint.
// =============================================================================

bind VX_tcu_core VX_tcu_tilefinal_sva #(
    .M_STEPS    (VX_tcu_pkg::TCU_M_STEPS),
    .N_STEPS    (VX_tcu_pkg::TCU_N_STEPS),
    .K_STEPS    (VX_tcu_pkg::TCU_K_STEPS),
    .WG_K_STEPS (VX_tcu_pkg::TCU_WG_K_STEPS),
    .UOPS       (VX_tcu_pkg::TCU_UOPS)
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
    .is_tile_final    (1'bx),                       // tag wrapper not in this build
    .header_eop       (execute_if.data.header.eop)
);
