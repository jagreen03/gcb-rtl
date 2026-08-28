// =============================================================================
// GreenCoyote-Bay — Top Level Integration (Corrected)
// Project: ODIN_Bridge / Cascaded Optical Reduction Fabric
// Author:  John A. Green
// Date:    June 2026
// =============================================================================
// Architecture:
//   greencoyote_top
//     ├── greencoyote_axi_lite_wrapper   AXI-Lite protocol front door only
//     ├── greencoyote_pilot_regs         MMIO register block
//     └── greencoyote_photonic_sequencer Optical reduction data plane
//
// pilot_regs sits at top level so all control signals are visible
// to both the AXI wrapper (MMIO r/w) and the sequencer (data plane).
// No control signals buried inside submodules.
// All port connections are explicit — no implicit .name shorthand.
// =============================================================================

module greencoyote_top (
    input  logic        user_clk,
    input  logic        peripheral_aresetn,

    // AXI-Lite Slave Interface — from Alveo U55C Vitis shell
    input  logic [5:0]  s_axi_awaddr,
    input  logic        s_axi_awvalid,
    output logic        s_axi_awready,
    input  logic [31:0] s_axi_wdata,
    input  logic [3:0]  s_axi_wstrb,
    input  logic        s_axi_wvalid,
    output logic        s_axi_wready,
    output logic [1:0]  s_axi_bresp,
    output logic        s_axi_bvalid,
    input  logic        s_axi_bready,
    input  logic [5:0]  s_axi_araddr,
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

    // DAC PHY interface — to laser drivers
    output logic [11:0] dac_data  [0:7],
    output logic [7:0]  dac_valid,
    output logic        dac_sync,

    // ADC PHY interface — from photodetector
    input  logic [11:0] adc_data,
    input  logic        adc_valid,

    // Interrupt to host CPU via Vitis shell
    output logic        interrupt
);

// =============================================================================
// Internal wires — AXI wrapper to pilot_regs
// =============================================================================

logic [5:0]  mmio_addr;
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
    .irq_out            (irq_out)
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

    // DAC PHY
    .dac_data           (dac_data),
    .dac_valid          (dac_valid),
    .dac_sync           (dac_sync),

    // ADC PHY
    .adc_data           (adc_data),
    .adc_valid          (adc_valid)
);

endmodule
