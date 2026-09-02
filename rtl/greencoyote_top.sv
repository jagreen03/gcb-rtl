// =============================================================================
// GreenCoyote-Bay — Top Level Integration
// Project: ODIN_Bridge / Cascaded Optical Reduction Fabric
// Author:  John A. Green
// Date:    June 2026
// =============================================================================
// Architecture:
//   greencoyote_top
//     ├── greencoyote_axi_lite_wrapper   AXI-Lite protocol front door only
//     ├── greencoyote_pilot_regs         MMIO register block (0x00-0xA8)
//     └── greencoyote_photonic_sequencer Optical reduction data plane
//
// pilot_regs sits at top level so all control signals are visible to both the
// AXI wrapper (MMIO r/w) and the data plane. All port connections are explicit.
//
// INTEGRATION STATUS
//   Implemented data plane : inference reduction (precision, calibration,
//                            gain trim, AUTO_FIRE, 2-pass 14-GPU reduction, IRQ).
//   Stubbed subsystems     : crossbar switch, learning appliance, gradient
//                            all-reduce, ISA execution engine, snapshot/rollback,
//                            OS task/power management.
//   The pilot_regs control registers for the stubbed subsystems are fully
//   wired out to this module's ports so the complete register map survives
//   synthesis and is exercisable from the host driver. Their *status* inputs
//   are tied off in the STUB TIE-OFFS block below — replace those connections
//   with the real subsystem status buses as each block is brought up.
// =============================================================================

module greencoyote_top (
    input  logic        user_clk,
    input  logic        peripheral_aresetn,

    // AXI-Lite Slave Interface — from Alveo U55C Vitis shell
    input  logic [7:0]  s_axi_awaddr,
    input  logic        s_axi_awvalid,
    output logic        s_axi_awready,
    input  logic [31:0] s_axi_wdata,
    input  logic [3:0]  s_axi_wstrb,
    input  logic        s_axi_wvalid,
    output logic        s_axi_wready,
    output logic [1:0]  s_axi_bresp,
    output logic        s_axi_bvalid,
    input  logic        s_axi_bready,
    input  logic [7:0]  s_axi_araddr,
    input  logic        s_axi_arvalid,
    output logic        s_axi_arready,
    output logic [31:0] s_axi_rdata,
    output logic [1:0]  s_axi_rresp,
    output logic        s_axi_rvalid,
    input  logic        s_axi_rready,

    // GPU partial sum buffer interface
    input  logic [31:0] buf_data [0:7],
    input  logic [7:0]  buf_full,
    output logic [7:0]  buf_clear,

    // Native DAC PHY — per-channel 12-bit bus to the laser drivers
    output logic [11:0] dac_data  [0:7],
    output logic [7:0]  dac_valid,
    output logic        dac_sync,

    // Parallel DAC interface — bench loopback stimulus (greencoyote_dac_if)
    // 14-bit word + channel-select + write strobe, generic parallel-DAC timing
    output logic [13:0] dac_p_data,
    output logic [2:0]  dac_p_chan,
    output logic        dac_p_clk,
    output logic        dac_p_wr_n,

    // SPI SAR ADC interface — bench loopback capture (greencoyote_adc_if)
    output logic        adc_sclk,
    output logic        adc_cs_n,
    output logic        adc_mosi,
    input  logic        adc_miso,

    // Interrupt to host CPU via Vitis shell
    output logic        interrupt,

    // -------------------------------------------------------------------------
    // Crossbar routing control -> optical switch (0x18-0x20)
    // -------------------------------------------------------------------------
    output logic [2:0]  xbar_port_dest [0:7],
    output logic [1:0]  xbar_mode,
    output logic        xbar_update,

    // -------------------------------------------------------------------------
    // Training / LoRA control -> learning appliance (0x24-0x2C)
    // -------------------------------------------------------------------------
    output logic        train_mode,
    output logic        dac_freeze,
    output logic        sidecar_enable,
    output logic [2:0]  lora_rank,
    output logic [15:0] alpha_scaled,
    output logic [15:0] lora_tile_row,
    output logic [15:0] lora_tile_col,

    // -------------------------------------------------------------------------
    // Scaled-learning / gradient all-reduce control (0x30-0x38)
    // -------------------------------------------------------------------------
    output logic [9:0]  cell_count,
    output logic        grad_reduce_en,
    output logic        grad_reduce_fire,
    output logic        auto_grad_reduce,
    output logic [23:0] grad_scale,
    output logic [1:0]  n_spi_buses,
    output logic [15:0] spi_clk_div,

    // -------------------------------------------------------------------------
    // ISA execution engine control -> instruction BRAM / interpreter (0x60-0x74)
    // -------------------------------------------------------------------------
    output logic        exec_start,
    output logic        exec_stop,
    output logic        exec_reset,
    output logic        exec_step,
    output logic [11:0] bram_wr_addr,
    output logic [31:0] bram_wr_data_lo,
    output logic [31:0] bram_wr_data_hi,
    output logic        bram_wr_en,
    output logic [15:0] lc_init [0:3],

    // -------------------------------------------------------------------------
    // Snapshot / rollback control (0x84)
    // -------------------------------------------------------------------------
    output logic        rollback_en,
    output logic [7:0]  rollback_limit,
    output logic        fault_irq_en,

    // -------------------------------------------------------------------------
    // OS task / power management control (0x90-0xA8)
    // -------------------------------------------------------------------------
    output logic [3:0]  active_tid,
    output logic [3:0]  target_tid,
    output logic        shutdown_init,
    output logic        emergency_shutdown_sw,
    output logic        flush_ombs,
    output logic        irq_before_power,
    output logic [11:0] shutdown_timeout_ms,
    output logic [8:0]  tile_select
);

// =============================================================================
// Internal wires — AXI wrapper to pilot_regs
// =============================================================================

logic [7:0]  mmio_addr;
logic [31:0] mmio_wdata;
logic        mmio_we;
logic        mmio_re;
logic [31:0] mmio_rdata;

// =============================================================================
// Internal wires — pilot_regs control outputs to sequencer
// =============================================================================

logic        fire;
logic        auto_fire;
logic [2:0]  mode_sel;
logic [1:0]  noise_headroom;
logic [1:0]  sat_guard;
logic [11:0] dark_offset;
logic [11:0] gain_trim_global;
logic        cal_valid;
logic        cal_lock;
logic [7:0]  trim_ch [0:7];

// =============================================================================
// Internal wires — sequencer status outputs to pilot_regs
// =============================================================================

logic        mode_active;
logic [1:0]  pass_index;
logic [3:0]  queue_depth;
logic        cal_err;
logic        fire_done;
logic        queue_full;

// =============================================================================
// Internal wires — interrupt
// =============================================================================

logic        irq_out;

// =============================================================================
// Internal wires — sequencer <-> bench ADC interface block
// (adc_data / adc_valid were external PHY inputs before the SPI loopback)
// =============================================================================

logic        dac_load_done;    // greencoyote_dac_if — all channels clocked out
logic [11:0] adc_data;         // greencoyote_adc_if -> sequencer
logic        adc_valid;
logic        conv_fault;

// conversion_start = dac_sync delayed by DAC-load + analog-settling headroom,
// so the SPI SAR conversion begins only once the optical value has settled.
localparam int FIRE_TO_CONV_DLY = 4;
logic [FIRE_TO_CONV_DLY-1:0] conv_dly;
logic        conversion_start;

always_ff @(posedge user_clk or negedge peripheral_aresetn) begin
    if (!peripheral_aresetn) conv_dly <= '0;
    else                     conv_dly <= {conv_dly[FIRE_TO_CONV_DLY-2:0], dac_sync};
end
assign conversion_start = conv_dly[FIRE_TO_CONV_DLY-1];

// =============================================================================
// Module: AXI-Lite Wrapper
// Protocol front door only — no register logic inside
// =============================================================================

greencoyote_axi_lite_wrapper u_axi_lite (
    .s_axi_aclk     (user_clk),
    .s_axi_aresetn  (peripheral_aresetn),

    .s_axi_awaddr   (s_axi_awaddr),
    .s_axi_awvalid  (s_axi_awvalid),
    .s_axi_awready  (s_axi_awready),

    .s_axi_wdata    (s_axi_wdata),
    .s_axi_wstrb    (s_axi_wstrb),
    .s_axi_wvalid   (s_axi_wvalid),
    .s_axi_wready   (s_axi_wready),

    .s_axi_bresp    (s_axi_bresp),
    .s_axi_bvalid   (s_axi_bvalid),
    .s_axi_bready   (s_axi_bready),

    .s_axi_araddr   (s_axi_araddr),
    .s_axi_arvalid  (s_axi_arvalid),
    .s_axi_arready  (s_axi_arready),

    .s_axi_rdata    (s_axi_rdata),
    .s_axi_rresp    (s_axi_rresp),
    .s_axi_rvalid   (s_axi_rvalid),
    .s_axi_rready   (s_axi_rready),

    // MMIO bus to pilot_regs
    .reg_addr       (mmio_addr),
    .reg_wdata      (mmio_wdata),
    .reg_write_en   (mmio_we),
    .reg_read_en    (mmio_re),
    .reg_rdata      (mmio_rdata),

    .interrupt      (interrupt),
    .irq_in         (irq_out)
);

// =============================================================================
// Module: Pilot Register Block
// MMIO registers — sits between AXI wrapper and sequencer
// =============================================================================

greencoyote_pilot_regs u_pilot_regs (
    .clk                (user_clk),
    .rst_n              (peripheral_aresetn),

    // MMIO interface from AXI wrapper
    .mmio_addr          (mmio_addr),
    .mmio_wdata         (mmio_wdata),
    .mmio_we            (mmio_we),
    .mmio_re            (mmio_re),
    .mmio_rdata         (mmio_rdata),

    // Precision mode outputs to sequencer
    .mode_sel           (mode_sel),
    .noise_headroom     (noise_headroom),
    .sat_guard          (sat_guard),

    // Calibration outputs to sequencer
    .dark_offset        (dark_offset),
    .gain_trim_global   (gain_trim_global),
    .cal_valid          (cal_valid),
    .cal_lock           (cal_lock),

    // Per-channel gain trim to sequencer
    .trim_ch            (trim_ch),

    // Control outputs to sequencer
    .fire               (fire),
    .auto_fire          (auto_fire),

    // Status inputs from sequencer
    .mode_active        (mode_active),
    .pass_index         (pass_index),
    .queue_depth        (queue_depth),
    .cal_err            (cal_err),
    .fire_done          (fire_done),
    .queue_full         (queue_full),

    // Interrupt output to AXI wrapper
    .irq_out            (irq_out),

    // ---- Crossbar routing (control out to ports, status stubbed) ----
    .xbar_port_dest     (xbar_port_dest),
    .xbar_mode          (xbar_mode),
    .xbar_update        (xbar_update),
    .xbar_ready         (1'b0),

    // ---- Training / LoRA (control out to ports, status stubbed) ----
    .train_mode         (train_mode),
    .dac_freeze         (dac_freeze),
    .sidecar_enable     (sidecar_enable),
    .lora_rank          (lora_rank),
    .alpha_scaled       (alpha_scaled),
    .lora_tile_row      (lora_tile_row),
    .lora_tile_col      (lora_tile_col),
    .update_pending     (1'b0),
    .update_active      (1'b0),
    .channels_updated   (16'h0000),
    .update_done        (1'b0),
    .checksum_pass      (1'b0),
    .checksum_fail      (1'b0),

    // ---- Scaled learning / gradient all-reduce ----
    .cells_ready        (10'h000),
    .grad_reduce_done   (1'b0),
    .cell_count         (cell_count),
    .grad_reduce_en     (grad_reduce_en),
    .grad_reduce_fire   (grad_reduce_fire),
    .auto_grad_reduce   (auto_grad_reduce),
    .grad_scale         (grad_scale),
    .n_spi_buses        (n_spi_buses),
    .spi_clk_div        (spi_clk_div),

    // ---- ISA execution engine (control out to ports, status stubbed) ----
    .exec_start         (exec_start),
    .exec_stop          (exec_stop),
    .exec_reset         (exec_reset),
    .exec_step          (exec_step),
    .bram_wr_addr       (bram_wr_addr),
    .bram_wr_data_lo    (bram_wr_data_lo),
    .bram_wr_data_hi    (bram_wr_data_hi),
    .bram_wr_en         (bram_wr_en),
    .lc_init            (lc_init),
    .exec_running       (1'b0),
    .exec_done          (1'b0),
    .exec_error         (1'b0),
    .exec_pc            (12'h000),
    .exec_opcode        (8'h00),
    .sync_pending       (16'h0000),
    .sync_timeout       (1'b0),
    .err_pc             (12'h000),
    .err_opcode         (8'h00),
    .err_cause          (4'h0),

    // ---- Snapshot / rollback (control out to ports, status stubbed) ----
    .snapshot_ready     (1'b0),
    .snapshot_running   (1'b0),
    .snap_diverge       (1'b0),
    .rollback_active    (1'b0),
    .rollback_complete  (1'b0),
    .systemic_fault     (1'b0),
    .restore_ok         (1'b0),
    .restore_fail       (1'b0),
    .snap_id_last       (8'h00),
    .snap_pc_last       (12'h000),
    .rollback_en        (rollback_en),
    .rollback_limit     (rollback_limit),
    .fault_irq_en       (fault_irq_en),
    .fault_cause        (4'h0),
    .fault_tile         (8'h00),
    .fault_pc           (12'h000),
    .fault_count        (4'h0),
    .snap_log_base      (12'h000),
    .snap_log_size      (12'h000),
    .snap_count         (8'h00),

    // ---- OS task / power management (control out to ports, status stubbed) ----
    .active_tid            (active_tid),
    .target_tid           (target_tid),
    .shutdown_init        (shutdown_init),
    .emergency_shutdown_sw (emergency_shutdown_sw),
    .flush_ombs           (flush_ombs),
    .irq_before_power     (irq_before_power),
    .shutdown_timeout_ms  (shutdown_timeout_ms),
    .tile_select          (tile_select),
    .task_count           (4'h0),
    .alloc_conflict       (1'b0),
    .switch_active        (1'b0),
    .shutdown_ready_status (1'b0),
    .tid_active_mask      (16'h0000),
    .tid_state           (8'h00),
    .tid_priority        (4'h0),
    .tid_pc              (12'h000),
    .tid_fault_count     (4'h0),
    .tid_anchor_valid    (1'b0),
    .tile_tid            (4'h0),
    .tile_allocated      (1'b0),
    .bw_tokens_remain    (16'h0000),
    .bw_quota_mbps_status (16'h0000),
    .sched_cycles        (32'h0000_0000),
    .power_off_assert    (1'b0),
    .all_tids_snapshotted (1'b0),
    .omb_flush_done      (1'b0)
);

// =============================================================================
// Module: Photonic Sequencer
// Data plane — drives DAC/ADC and manages reduction state machine
// =============================================================================

greencoyote_photonic_sequencer u_sequencer (
    .clk                (user_clk),
    .rst_n              (peripheral_aresetn),

    // Control inputs from pilot_regs
    .fire               (fire),
    .auto_fire          (auto_fire),
    .mode_sel           (mode_sel),
    .sat_guard          (sat_guard),
    .noise_headroom     (noise_headroom),
    .dark_offset        (dark_offset),
    .trim_ch            (trim_ch),

    // Status outputs to pilot_regs
    .mode_active        (mode_active),
    .pass_index         (pass_index),
    .queue_depth        (queue_depth),
    .cal_err            (cal_err),
    .fire_done          (fire_done),
    .queue_full         (queue_full),

    // GPU buffer interface
    .buf_data           (buf_data),
    .buf_full           (buf_full),
    .buf_clear          (buf_clear),

    // DAC PHY (internal — consumed by greencoyote_dac_if)
    .dac_data           (dac_data),
    .dac_valid          (dac_valid),
    .dac_sync           (dac_sync),

    // ADC PHY (internal — driven by greencoyote_adc_if)
    .adc_data           (adc_data),
    .adc_valid          (adc_valid),
    .conv_fault         (conv_fault)
);

// =============================================================================
// Module: Parallel DAC Interface — bench loopback stimulus
// =============================================================================

greencoyote_dac_if u_dac_if (
    .clk           (user_clk),
    .rst_n         (peripheral_aresetn),
    .fire          (dac_sync),
    .trim_ch       (trim_ch),
    .dac_p_data    (dac_p_data),
    .dac_p_chan    (dac_p_chan),
    .dac_p_clk     (dac_p_clk),
    .dac_p_wr_n    (dac_p_wr_n),
    .dac_load_done (dac_load_done)
);

// =============================================================================
// Module: SPI SAR ADC Interface — bench loopback capture
// =============================================================================

greencoyote_adc_if #(
    .SCLK_DIV      (2),
    .SETTLE_CYCLES (6)
) u_adc_if (
    .clk              (user_clk),
    .rst_n            (peripheral_aresetn),
    .conversion_start (conversion_start),
    .adc_sclk         (adc_sclk),
    .adc_cs_n         (adc_cs_n),
    .adc_mosi         (adc_mosi),
    .adc_miso         (adc_miso),
    .adc_data         (adc_data),
    .adc_valid        (adc_valid),
    .conv_fault       (conv_fault)
);

endmodule
