// =============================================================================
// GreenCoyote-Bay Pilot FPGA — MMIO Register Block
// Project: ODIN_Bridge / Cascaded Optical Reduction Fabric
// Author:  John A. Green
// Date:    June 2026
// =============================================================================
// Register Map:
//   0x00  Precision Mode Configuration
//   0x04  Global Calibration
//   0x08  Channel Gain Trim 0-3
//   0x0C  Channel Gain Trim 4-7
//   0x10  Reduction Control and Status
//   0x14  Interrupt Control
//   0x18  Crossbar Routing Low  (ports 0-3)
//   0x1C  Crossbar Routing High (ports 4-7)
//   0x20  Crossbar Mode and Status
//   0x24  Training Mode Control
//   0x28  Gradient Update Status
//   0x2C  LoRA Tile Address
//   0x30  Cell Count and Sync Status
//   0x34  Gradient All-Reduce Control
//   0x38  SPI Bus Configuration
//   0x40  Thermal Target
//   0x44  Thermistor Telemetry 0
//   0x48  Thermistor Telemetry 1
//   0x4C  TEC Control Status
//   0x50  Thermal Guard Rail Status
//   0x54  Thermal Log
//   0x58  Thermal IRQ Control
//   0x5C  TEC PID Coefficients
//   0x60  Execution Control
//   0x64  BRAM Write Address
//   0x68  BRAM Write Data Low
//   0x6C  BRAM Write Data High (triggers BRAM write)
//   0x70  Loop Counter Load Low  (LC0, LC1)
//   0x74  Loop Counter Load High (LC2, LC3)
//   0x78  Sync Status
//   0x7C  Execution Error Log
//   0x80  Snapshot Status
//   0x84  Rollback Control
//   0x88  Fault Log
//   0x8C  Snapshot Log Pointer
//   0x90  Task Allocation Control
//   0x94  TID Status
//   0x98  Tile Allocation Map Read
//   0x9C  Tile Select
//   0xA0  Rate Limit Status
//   0xA4  Scheduler Statistics
//   0xA8  Shutdown Control
// =============================================================================

module greencoyote_pilot_regs #(
    parameter NUM_CHANNELS = 8
)(
    input  wire         clk,
    input  wire         rst_n,

    // Host CPU MMIO interface (AXI-Lite style)
    input  wire [5:0]   mmio_addr,      // 6-bit address covers 0x00-0x3C
    input  wire [31:0]  mmio_wdata,
    input  wire         mmio_we,
    input  wire         mmio_re,
    output reg  [31:0]  mmio_rdata,

    // Precision mode outputs to DAC/ADC pipeline
    output reg  [2:0]   mode_sel,       // 000=INT4 001=FP4 010=FP8 011=BF16
    output reg  [1:0]   noise_headroom,
    output reg  [1:0]   sat_guard,

    // Calibration outputs
    output reg  [11:0]  dark_offset,
    output reg  [11:0]  gain_trim_global,
    output reg          cal_valid,
    output reg          cal_lock,

    // Per-channel gain trim outputs
    output reg  [7:0]   trim_ch [0:7],

    // Reduction control outputs
    output reg          fire,            // pulses one cycle
    output reg          auto_fire,

    // Reduction status inputs
    input  wire         mode_active,
    input  wire [1:0]   pass_index,
    input  wire [3:0]   queue_depth,
    input  wire         cal_err,
    input  wire         fire_done,
    input  wire         queue_full,

    // Interrupt output to host CPU
    output reg          irq_out,

    // Crossbar routing outputs to optical switch
    // Each port_dest field: 000-110=route to GPU N, 111=broadcast, 110=reduce, 101=pipeline-next
    output reg  [2:0]   xbar_port_dest [0:7],  // Destination per input port
    output reg  [1:0]   xbar_mode,             // 00=tensor 01=pipeline 10=moe 11=custom
    output reg          xbar_update,            // Pulses one cycle when routing changes
    input  wire         xbar_ready,             // Switch confirms new routing applied

    // Training mode outputs to Learning Appliance
    output reg          train_mode,             // 0=inference 1=LoRA adaptation enabled
    output reg          dac_freeze,             // 1=freeze sidecar DACs during forward pass
    output reg          sidecar_enable,         // 1=sidecar outputs active in MMI combiner
    output reg  [2:0]   lora_rank,              // Encoded rank
    output reg  [15:0]  alpha_scaled,           // α/r as Q8.8 fixed-point
    output reg  [15:0]  lora_tile_row,          // Current sidecar DAC row
    output reg  [15:0]  lora_tile_col,          // Current sidecar DAC column

    // Training mode status inputs from Learning Appliance
    input  wire         update_pending,         // Gradient update waiting for idle window
    input  wire         update_active,          // DAC update in progress
    input  wire [15:0]  channels_updated,       // DAC channels written in current update
    input  wire         update_done,            // Pulse when full update committed
    input  wire         checksum_pass,          // Weight checksum verified
    input  wire         checksum_fail,          // Checksum mismatch detected

    // Scaled learning inputs
    input  wire [9:0]   cells_ready,            // Count of cells asserting update_done
    input  wire         grad_reduce_done,       // Optical gradient all-reduce complete

    // Scaled learning outputs
    output reg  [9:0]   cell_count,             // Total Training Cells in fabric
    output reg          grad_reduce_en,         // Enable optical gradient all-reduce
    output reg          grad_reduce_fire,       // Trigger gradient reduction
    output reg          auto_grad_reduce,       // Fire automatically when all cells ready
    output reg  [23:0]  grad_scale,             // Global gradient scaling Q8.16
    output reg  [1:0]   n_spi_buses,            // Parallel SPI buses per cell
    output reg  [15:0]  spi_clk_div,            // SPI clock divider

    // ISA execution outputs
    output reg          exec_start,             // Begin program execution
    output reg          exec_stop,              // Halt after current instruction
    output reg          exec_reset,             // Reset PC to 0
    output reg          exec_step,              // Single-step mode
    output reg  [11:0]  bram_wr_addr,           // BRAM write address
    output reg  [31:0]  bram_wr_data_lo,        // BRAM write data low 32 bits
    output reg  [31:0]  bram_wr_data_hi,        // BRAM write data high 32 bits
    output reg          bram_wr_en,             // BRAM write enable pulse
    output reg  [15:0]  lc_init [0:3],          // Loop counter initial values

    // ISA execution status inputs
    input  wire         exec_running,           // Interpreter active
    input  wire         exec_done,              // HALT reached
    input  wire         exec_error,             // Invalid opcode or timeout
    input  wire [11:0]  exec_pc,                // Current program counter
    input  wire [7:0]   exec_opcode,            // Current opcode
    input  wire [15:0]  sync_pending,           // SYNC_ID being awaited
    input  wire         sync_timeout,           // Last SYNC timed out
    input  wire [11:0]  err_pc,                 // PC at error
    input  wire [7:0]   err_opcode,             // Opcode at error
    input  wire [3:0]   err_cause,              // Error cause code

    // Snapshot status inputs
    input  wire         snapshot_ready,         // Snapshot capture complete
    input  wire         snapshot_running,       // Snapshot in progress
    input  wire         snap_diverge,           // CRC mismatch vs previous
    input  wire         rollback_active,        // Rollback in progress
    input  wire         rollback_complete,      // Rollback completed
    input  wire         systemic_fault,         // Rollback limit exceeded
    input  wire         restore_ok,             // All tiles confirmed restore
    input  wire         restore_fail,           // Tile CRC mismatch after restore
    input  wire [7:0]   snap_id_last,           // SNAP_ID of most recent snapshot
    input  wire [11:0]  snap_pc_last,           // PC of most recent snapshot

    // Snapshot control outputs
    output reg          rollback_en,            // Enable automatic rollback
    output reg  [7:0]   rollback_limit,         // Max rollbacks before systemic fault
    output reg          fault_irq_en,           // IRQ on any fault

    // Fault log inputs
    input  wire [3:0]   fault_cause,            // Last fault cause
    input  wire [7:0]   fault_tile,             // Tile that triggered fault
    input  wire [11:0]  fault_pc,               // PC at fault
    input  wire [3:0]   fault_count,            // Faults since last clear

    // Snapshot log pointer inputs
    input  wire [11:0]  snap_log_base,          // BRAM address of latest snapshot
    input  wire [11:0]  snap_log_size,          // Size of latest snapshot
    input  wire [7:0]   snap_count,             // Total snapshots taken

    // OS task management outputs
    output reg  [3:0]   active_tid,             // Currently selected TID for status reads
    output reg  [3:0]   target_tid,             // TID for next CONTEXT_SWITCH
    output reg          shutdown_init,          // Initiate ordered shutdown
    output reg          emergency_shutdown_sw,  // Software emergency shutdown
    output reg          flush_ombs,             // Include OMB flush in shutdown
    output reg          irq_before_power,       // IRQ before POWER_OFF
    output reg  [11:0]  shutdown_timeout_ms,    // Timeout for TID snapshot collection
    output reg  [8:0]   tile_select,            // Tile index for allocation map query

    // OS task management status inputs
    input  wire [3:0]   task_count,             // Number of allocated TIDs
    input  wire         alloc_conflict,         // Tile allocation conflict
    input  wire         switch_active,          // CONTEXT_SWITCH in progress
    input  wire         shutdown_ready_status,  // All TIDs snapshotted
    input  wire [15:0]  tid_active_mask,        // Bitmask of running TIDs
    input  wire [7:0]   tid_state,              // State of ACTIVE_TID
    input  wire [3:0]   tid_priority,           // Priority of ACTIVE_TID
    input  wire [11:0]  tid_pc,                 // PC of ACTIVE_TID
    input  wire [3:0]   tid_fault_count,        // Faults for ACTIVE_TID
    input  wire         tid_anchor_valid,       // ACTIVE_TID has valid anchor
    input  wire [3:0]   tile_tid,               // TID owning TILE_SELECT
    input  wire         tile_allocated,         // TILE_SELECT is allocated
    input  wire [15:0]  bw_tokens_remain,       // Token bucket for ACTIVE_TID
    input  wire [15:0]  bw_quota_mbps_status,   // Quota for ACTIVE_TID
    input  wire [31:0]  sched_cycles,           // Scheduler cycle fractions TID0-3
    input  wire         power_off_assert,       // POWER_OFF pin status
    input  wire         all_tids_snapshotted,   // All TIDs have SNAPSHOT_READY
    input  wire         omb_flush_done          // OMB forensics flushed
);

// =============================================================================
// Internal registers
// =============================================================================

// 0x00 Precision Mode Configuration
reg [2:0]   r_mode_sel;
reg [1:0]   r_noise_headroom;
reg [1:0]   r_sat_guard;

// 0x04 Global Calibration
reg [11:0]  r_dark_offset;
reg [11:0]  r_gain_trim_global;
reg         r_cal_valid;
reg         r_cal_lock;

// 0x08 Channel Gain Trim 0-3
reg [7:0]   r_trim_ch0;
reg [7:0]   r_trim_ch1;
reg [7:0]   r_trim_ch2;
reg [7:0]   r_trim_ch3;

// 0x0C Channel Gain Trim 4-7
reg [7:0]   r_trim_ch4;
reg [7:0]   r_trim_ch5;
reg [7:0]   r_trim_ch6;
reg [7:0]   r_trim_ch7;

// 0x10 Reduction Control
reg         r_auto_fire;
reg         r_fire_pulse;

// 0x14 Interrupt Control
reg         r_irq_en;
reg         r_irq_fire_done_en;
reg         r_irq_cal_err_en;
reg         r_irq_queue_full_en;
reg         r_irq_pass_done_en;
reg         r_irq_status;

// 0x18 Crossbar Routing Low — ports 0-3
reg [2:0]   r_xbar_dest0;
reg [2:0]   r_xbar_dest1;
reg [2:0]   r_xbar_dest2;
reg [2:0]   r_xbar_dest3;

// 0x1C Crossbar Routing High — ports 4-7
reg [2:0]   r_xbar_dest4;
reg [2:0]   r_xbar_dest5;
reg [2:0]   r_xbar_dest6;
reg [2:0]   r_xbar_dest7;

// 0x20 Crossbar Mode and Status
reg [1:0]   r_xbar_mode;        // 00=tensor 01=pipeline 10=moe 11=custom
reg         r_xbar_update;      // Self-clearing update strobe

// 0x24 Training Mode Control
reg         r_train_mode;
reg         r_dac_freeze;
reg         r_sidecar_enable;
reg [2:0]   r_lora_rank;
reg [15:0]  r_alpha_scaled;

// 0x2C LoRA Tile Address
reg [15:0]  r_lora_tile_row;
reg [15:0]  r_lora_tile_col;

// 0x30 Cell Count and Sync Status
reg [9:0]   r_cell_count;

// 0x34 Gradient All-Reduce Control
reg         r_grad_reduce_en;
reg         r_grad_reduce_fire;
reg         r_auto_grad_reduce;
reg [23:0]  r_grad_scale;

// 0x38 SPI Bus Configuration
reg [1:0]   r_n_spi_buses;
reg [15:0]  r_spi_clk_div;

// ISA execution registers 0x60-0x7C
reg         r_exec_start;
reg         r_exec_stop;
reg         r_exec_reset;
reg         r_exec_step;
reg [11:0]  r_bram_wr_addr;
reg [31:0]  r_bram_wr_data_lo;
reg [31:0]  r_bram_wr_data_hi;
reg         r_bram_wr_en;
reg [15:0]  r_lc_init [0:3];

// Snapshot registers 0x80-0x8C
reg         r_rollback_en;
reg [7:0]   r_rollback_limit;
reg         r_fault_irq_en;

// OS registers 0x90-0xA8
reg [3:0]   r_active_tid;
reg [3:0]   r_target_tid;
reg         r_shutdown_init;
reg         r_emergency_shutdown_sw;
reg         r_flush_ombs;
reg         r_irq_before_power;
reg [11:0]  r_shutdown_timeout_ms;
reg [8:0]   r_tile_select;

// Internal signals
reg         fire_done_prev;
reg         pass_done_prev;
reg [1:0]   pass_index_prev;

// =============================================================================
// Write logic
// =============================================================================

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        r_mode_sel          <= 3'b010;  // Default FP8 — tightest constraint
        r_noise_headroom    <= 2'b01;
        r_sat_guard         <= 2'b01;
        r_dark_offset       <= 12'h000;
        r_gain_trim_global  <= 12'h000;
        r_cal_valid         <= 1'b0;
        r_cal_lock          <= 1'b0;
        r_trim_ch0          <= 8'hFF;   // Unity gain default
        r_trim_ch1          <= 8'hFF;
        r_trim_ch2          <= 8'hFF;
        r_trim_ch3          <= 8'hFF;
        r_trim_ch4          <= 8'hFF;
        r_trim_ch5          <= 8'hFF;
        r_trim_ch6          <= 8'hFF;
        r_trim_ch7          <= 8'hFF;
        r_auto_fire         <= 1'b0;
        r_fire_pulse        <= 1'b0;
        r_irq_en            <= 1'b0;
        r_irq_fire_done_en  <= 1'b0;
        r_irq_cal_err_en    <= 1'b0;
        r_irq_queue_full_en <= 1'b0;
        r_irq_pass_done_en  <= 1'b0;
        r_irq_status        <= 1'b0;
        // Crossbar reset — default tensor parallel (all ports broadcast)
        r_xbar_dest0        <= 3'b111;  // broadcast
        r_xbar_dest1        <= 3'b111;
        r_xbar_dest2        <= 3'b111;
        r_xbar_dest3        <= 3'b111;
        r_xbar_dest4        <= 3'b111;
        r_xbar_dest5        <= 3'b111;
        r_xbar_dest6        <= 3'b111;
        r_xbar_dest7        <= 3'b111;
        r_xbar_mode         <= 2'b00;   // tensor parallel default
        r_xbar_update       <= 1'b0;
        // Training mode reset — inference only, sidecar enabled, DACs frozen safe
        r_train_mode        <= 1'b0;
        r_dac_freeze        <= 1'b1;   // Safe default: freeze sidecar DACs
        r_sidecar_enable    <= 1'b0;   // Sidecar disabled until LoRA loaded
        r_lora_rank         <= 3'b001; // Default rank 8
        r_alpha_scaled      <= 16'h0100; // Default α/r = 1.0 in Q8.8
        r_lora_tile_row     <= 16'h0;
        r_lora_tile_col     <= 16'h0;
        // Scaled learning reset
        r_cell_count        <= 10'h8;    // Default 8 cells
        r_grad_reduce_en    <= 1'b0;
        r_grad_reduce_fire  <= 1'b0;
        r_auto_grad_reduce  <= 1'b0;
        r_grad_scale        <= 24'h010000; // Default scale 1.0 in Q8.16
        r_n_spi_buses       <= 2'b00;    // Default 1 SPI bus
        r_spi_clk_div       <= 16'h0004; // Default divide by 4
        // ISA execution reset
        r_exec_start        <= 1'b0;
        r_exec_stop         <= 1'b0;
        r_exec_reset        <= 1'b0;
        r_exec_step         <= 1'b0;
        r_bram_wr_addr      <= 12'h000;
        r_bram_wr_data_lo   <= 32'h0;
        r_bram_wr_data_hi   <= 32'h0;
        r_bram_wr_en        <= 1'b0;
        r_lc_init[0]        <= 16'h0;
        r_lc_init[1]        <= 16'h0;
        r_lc_init[2]        <= 16'h0;
        r_lc_init[3]        <= 16'h0;
        // Snapshot reset — rollback enabled by default, limit=3
        r_rollback_en       <= 1'b1;
        r_rollback_limit    <= 8'h03;
        r_fault_irq_en      <= 1'b1;
        // OS reset
        r_active_tid        <= 4'h0;
        r_target_tid        <= 4'h0;
        r_shutdown_init     <= 1'b0;
        r_emergency_shutdown_sw <= 1'b0;
        r_flush_ombs        <= 1'b1;   // Default: flush OMBs on shutdown
        r_irq_before_power  <= 1'b1;   // Default: IRQ before power off
        r_shutdown_timeout_ms <= 12'hFA0; // Default 4 second timeout
        r_tile_select       <= 9'h000;
    end else begin

        // Auto-clear FIRE pulse after one cycle
        r_fire_pulse       <= 1'b0;
        r_grad_reduce_fire <= 1'b0;
        // Auto-clear crossbar update strobe after one cycle
        r_xbar_update <= 1'b0;

        // AUTO_GRAD_REDUCE — fire gradient reduction when all cells ready
        if (r_auto_grad_reduce && r_grad_reduce_en &&
            (cells_ready >= r_cell_count) && !grad_reduce_done)
            r_grad_reduce_fire <= 1'b1;

        if (mmio_we) begin
            case (mmio_addr)

                // 0x00 Precision Mode Configuration
                6'h00: begin
                    r_mode_sel       <= mmio_wdata[2:0];
                    r_noise_headroom <= mmio_wdata[4:3];
                    r_sat_guard      <= mmio_wdata[6:5];
                end

                // 0x04 Global Calibration
                6'h04: begin
                    if (!r_cal_lock) begin  // Writes blocked when CAL_LOCK set
                        r_dark_offset      <= mmio_wdata[11:0];
                        r_gain_trim_global <= mmio_wdata[23:12];
                        r_cal_valid        <= mmio_wdata[24];
                    end
                    r_cal_lock <= mmio_wdata[25];  // CAL_LOCK always writable
                end

                // 0x08 Channel Gain Trim 0-3
                6'h08: begin
                    r_trim_ch0 <= mmio_wdata[7:0];
                    r_trim_ch1 <= mmio_wdata[15:8];
                    r_trim_ch2 <= mmio_wdata[23:16];
                    r_trim_ch3 <= mmio_wdata[31:24];
                end

                // 0x0C Channel Gain Trim 4-7
                6'h0C: begin
                    r_trim_ch4 <= mmio_wdata[7:0];
                    r_trim_ch5 <= mmio_wdata[15:8];
                    r_trim_ch6 <= mmio_wdata[23:16];
                    r_trim_ch7 <= mmio_wdata[31:24];
                end

                // 0x10 Reduction Control
                6'h10: begin
                    if (mmio_wdata[0])    // FIRE bit — self-clearing
                        r_fire_pulse <= 1'b1;
                    r_auto_fire <= mmio_wdata[10];
                end

                // 0x14 Interrupt Control
                6'h14: begin
                    r_irq_en            <= mmio_wdata[0];
                    r_irq_fire_done_en  <= mmio_wdata[1];
                    r_irq_cal_err_en    <= mmio_wdata[2];
                    r_irq_queue_full_en <= mmio_wdata[3];
                    r_irq_pass_done_en  <= mmio_wdata[4];
                    if (mmio_wdata[9])   // IRQ_CLEAR
                        r_irq_status <= 1'b0;
                end

                // 0x18 Crossbar Routing Low — ports 0-3
                // [2:0]=port0 [5:3]=port1 [8:6]=port2 [11:9]=port3
                // Dest encoding: 000-110=GPU N, 111=broadcast, 110=reduce stage, 101=pipeline-next
                6'h18: begin
                    r_xbar_dest0  <= mmio_wdata[2:0];
                    r_xbar_dest1  <= mmio_wdata[5:3];
                    r_xbar_dest2  <= mmio_wdata[8:6];
                    r_xbar_dest3  <= mmio_wdata[11:9];
                    r_xbar_update <= 1'b1;  // Strobe switch to apply new routing
                end

                // 0x1C Crossbar Routing High — ports 4-7
                6'h1C: begin
                    r_xbar_dest4  <= mmio_wdata[2:0];
                    r_xbar_dest5  <= mmio_wdata[5:3];
                    r_xbar_dest6  <= mmio_wdata[8:6];
                    r_xbar_dest7  <= mmio_wdata[11:9];
                    r_xbar_update <= 1'b1;
                end

                // 0x20 Crossbar Mode and Status
                // [1:0]=XBAR_MODE 00=tensor 01=pipeline 10=moe 11=custom
                6'h20: begin
                    r_xbar_mode   <= mmio_wdata[1:0];
                    r_xbar_update <= 1'b1;
                end

                // 0x24 Training Mode Control
                // [0]=TRAIN_MODE [1]=DAC_FREEZE [4]=SIDECAR_ENABLE
                // [7:5]=LORA_RANK [23:8]=ALPHA_SCALED
                6'h24: begin
                    r_train_mode     <= mmio_wdata[0];
                    r_dac_freeze     <= mmio_wdata[1];
                    r_sidecar_enable <= mmio_wdata[4];
                    r_lora_rank      <= mmio_wdata[7:5];
                    r_alpha_scaled   <= mmio_wdata[23:8];
                end

                // 0x2C LoRA Tile Address
                6'h2C: begin
                    r_lora_tile_row <= mmio_wdata[15:0];
                    r_lora_tile_col <= mmio_wdata[31:16];
                end

                // 0x30 Cell Count (host writes total cell count at init)
                6'h30: begin
                    r_cell_count <= mmio_wdata[9:0];
                end

                // 0x34 Gradient All-Reduce Control
                // [0]=GRAD_REDUCE_EN [1]=GRAD_REDUCE_FIRE(self-clear)
                // [2]=AUTO_GRAD_REDUCE [31:8]=GRAD_SCALE Q8.16
                6'h34: begin
                    r_grad_reduce_en   <= mmio_wdata[0];
                    if (mmio_wdata[1])
                        r_grad_reduce_fire <= 1'b1; // Self-clearing
                    r_auto_grad_reduce <= mmio_wdata[2];
                    r_grad_scale       <= mmio_wdata[31:8];
                end

                // 0x38 SPI Bus Configuration
                // [1:0]=N_SPI_BUSES [23:8]=SPI_CLK_DIV
                6'h38: begin
                    r_n_spi_buses  <= mmio_wdata[1:0];
                    r_spi_clk_div  <= mmio_wdata[23:8];
                end

                // 0x60 Execution Control
                // [0]=EXEC_START [1]=EXEC_STOP [2]=EXEC_RESET [3]=EXEC_STEP
                6'h60: begin
                    r_exec_start <= mmio_wdata[0];
                    r_exec_stop  <= mmio_wdata[1];
                    r_exec_reset <= mmio_wdata[2];
                    r_exec_step  <= mmio_wdata[3];
                end

                // 0x64 BRAM Write Address
                6'h64: begin
                    r_bram_wr_addr <= mmio_wdata[11:0];
                    r_bram_wr_en   <= 1'b0; // Clear — wait for 0x6C write
                end

                // 0x68 BRAM Write Data Low
                6'h68: begin
                    r_bram_wr_data_lo <= mmio_wdata;
                    r_bram_wr_en      <= 1'b0;
                end

                // 0x6C BRAM Write Data High — triggers BRAM write
                6'h6C: begin
                    r_bram_wr_data_hi <= mmio_wdata;
                    r_bram_wr_en      <= 1'b1; // Pulse — write assembled instruction
                    r_bram_wr_addr    <= r_bram_wr_addr + 1; // Auto-increment
                end

                // 0x70 Loop Counter Load Low (LC0, LC1)
                6'h70: begin
                    r_lc_init[0] <= mmio_wdata[15:0];
                    r_lc_init[1] <= mmio_wdata[31:16];
                end

                // 0x74 Loop Counter Load High (LC2, LC3)
                6'h74: begin
                    r_lc_init[2] <= mmio_wdata[15:0];
                    r_lc_init[3] <= mmio_wdata[31:16];
                end

                // 0x84 Rollback Control
                // [29]=ROLLBACK_EN [15:8]=ROLLBACK_LIMIT [28]=FAULT_IRQ_EN
                6'h84: begin
                    r_rollback_limit <= mmio_wdata[15:8];
                    r_rollback_en    <= mmio_wdata[29];
                    r_fault_irq_en   <= mmio_wdata[28];
                end

                // 0x90 Task Allocation Control
                // [3:0]=ACTIVE_TID [7:4]=TARGET_TID [15]=SHUTDOWN_ACK
                6'h90: begin
                    r_active_tid <= mmio_wdata[3:0];
                    r_target_tid <= mmio_wdata[7:4];
                end

                // 0x98 Tile Select (for allocation map query)
                6'h9C: begin
                    r_tile_select <= mmio_wdata[8:0];
                end

                // 0xA8 Shutdown Control
                // [0]=SHUTDOWN_INIT [1]=EMERGENCY [2]=FLUSH_OMBS
                // [3]=IRQ_BEFORE_POWER [15:4]=SHUTDOWN_TIMEOUT_MS
                6'hA8: begin
                    r_shutdown_init        <= mmio_wdata[0];
                    r_emergency_shutdown_sw <= mmio_wdata[1];
                    r_flush_ombs           <= mmio_wdata[2];
                    r_irq_before_power     <= mmio_wdata[3];
                    r_shutdown_timeout_ms  <= mmio_wdata[15:4];
                end

            endcase
        end

        // AUTO_FIRE logic — trigger on queue full when enabled
        if (r_auto_fire && queue_full && !mode_active)
            r_fire_pulse <= 1'b1;

        // Interrupt status logic
        fire_done_prev   <= fire_done;
        pass_index_prev  <= pass_index;
        pass_done_prev   <= (pass_index != pass_index_prev);

        if (r_irq_en) begin
            if (r_irq_fire_done_en  && fire_done && !fire_done_prev)  r_irq_status <= 1'b1;
            if (r_irq_cal_err_en    && cal_err)                        r_irq_status <= 1'b1;
            if (r_irq_queue_full_en && queue_full)                     r_irq_status <= 1'b1;
            if (r_irq_pass_done_en  && pass_done_prev)                 r_irq_status <= 1'b1;
        end

    end
end

// =============================================================================
// Read logic
// =============================================================================

always @(posedge clk) begin
    if (mmio_re) begin
        case (mmio_addr)

            6'h00: mmio_rdata <= {24'h0,
                                   1'b0,
                                   r_sat_guard,
                                   r_noise_headroom,
                                   r_mode_sel};

            6'h04: mmio_rdata <= {6'h0,
                                   r_cal_lock,
                                   r_cal_valid,
                                   r_gain_trim_global,
                                   r_dark_offset};

            6'h08: mmio_rdata <= {r_trim_ch3,
                                   r_trim_ch2,
                                   r_trim_ch1,
                                   r_trim_ch0};

            6'h0C: mmio_rdata <= {r_trim_ch7,
                                   r_trim_ch6,
                                   r_trim_ch5,
                                   r_trim_ch4};

            6'h10: mmio_rdata <= {21'h0,
                                   r_auto_fire,      // [10]
                                   fire_done,        // [9]
                                   cal_err,          // [8]
                                   queue_depth,      // [7:4]
                                   pass_index,       // [3:2]
                                   mode_active,      // [1]
                                   1'b0};            // [0] FIRE reads as 0 (self-clearing)

            6'h14: mmio_rdata <= {22'h0,
                                   r_irq_status,     // [8] read only
                                   3'h0,
                                   r_irq_pass_done_en,
                                   r_irq_queue_full_en,
                                   r_irq_cal_err_en,
                                   r_irq_fire_done_en,
                                   r_irq_en};

            6'h18: mmio_rdata <= {20'h0,
                                   r_xbar_dest3,     // [11:9]
                                   r_xbar_dest2,     // [8:6]
                                   r_xbar_dest1,     // [5:3]
                                   r_xbar_dest0};    // [2:0]

            6'h1C: mmio_rdata <= {20'h0,
                                   r_xbar_dest7,     // [11:9]
                                   r_xbar_dest6,     // [8:6]
                                   r_xbar_dest5,     // [5:3]
                                   r_xbar_dest4};    // [2:0]

            6'h20: mmio_rdata <= {29'h0,
                                   xbar_ready,       // [2] switch ready status input
                                   r_xbar_mode};     // [1:0]

            6'h24: mmio_rdata <= {8'h0,
                                   r_alpha_scaled,   // [23:8]
                                   r_lora_rank,      // [7:5]
                                   1'b0,             // [4] SIDECAR_ENABLE readback
                                   update_active,    // [3]
                                   update_pending,   // [2]
                                   r_dac_freeze,     // [1]
                                   r_train_mode};    // [0]

            6'h28: mmio_rdata <= {13'h0,
                                   checksum_fail,    // [18]
                                   checksum_pass,    // [17]
                                   update_done,      // [16]
                                   channels_updated};// [15:0]

            6'h2C: mmio_rdata <= {r_lora_tile_col,  // [31:16]
                                   r_lora_tile_row}; // [15:0]

            6'h30: mmio_rdata <= {11'h0,
                                   grad_reduce_done, // [21]
                                   1'b0,             // [20] ALL_CELLS_READY computed
                                   cells_ready,      // [19:10]
                                   r_cell_count};    // [9:0]

            6'h34: mmio_rdata <= {r_grad_scale,      // [31:8]
                                   5'h0,
                                   r_auto_grad_reduce,// [2]
                                   1'b0,             // [1] self-clearing
                                   r_grad_reduce_en};// [0]

            6'h38: mmio_rdata <= {8'h0,
                                   r_spi_clk_div,    // [23:8]
                                   6'h0,
                                   r_n_spi_buses};   // [1:0]

            6'h60: mmio_rdata <= {exec_opcode,       // [31:24]
                                   exec_pc[11:0],    // [23:12] (padded)
                                   1'b0,
                                   exec_error,       // [10]
                                   exec_done,        // [9]
                                   exec_running,     // [8]
                                   4'h0,
                                   r_exec_step,      // [3]
                                   r_exec_reset,     // [2]
                                   r_exec_stop,      // [1]
                                   r_exec_start};    // [0]

            6'h64: mmio_rdata <= {20'h0, r_bram_wr_addr};

            6'h68: mmio_rdata <= r_bram_wr_data_lo;

            6'h6C: mmio_rdata <= r_bram_wr_data_hi;

            6'h70: mmio_rdata <= {r_lc_init[1], r_lc_init[0]};

            6'h74: mmio_rdata <= {r_lc_init[3], r_lc_init[2]};

            6'h78: mmio_rdata <= {14'h0,
                                   sync_timeout,     // [17]
                                   1'b0,
                                   sync_pending};    // [15:0]

            6'h7C: mmio_rdata <= {8'h0,
                                   err_cause,        // [27:24] — padded in 31:28
                                   err_opcode,       // [19:12]
                                   err_pc};          // [11:0]

            6'h80: mmio_rdata <= {4'h0,
                                   snap_pc_last,     // [27:16]
                                   snap_id_last,     // [15:8]
                                   restore_fail,     // [7]
                                   restore_ok,       // [6]
                                   systemic_fault,   // [5]
                                   rollback_complete,// [4]
                                   rollback_active,  // [3]
                                   snap_diverge,     // [2]
                                   snapshot_running, // [1]
                                   snapshot_ready};  // [0]

            6'h84: mmio_rdata <= {2'h0,
                                   r_rollback_en,    // [29]
                                   r_fault_irq_en,   // [28]
                                   snap_pc_last,     // [27:16]
                                   r_rollback_limit, // [15:8]
                                   8'h0};            // [7:0] rollback_count from interp

            6'h88: mmio_rdata <= {3'h0,
                                   r_fault_irq_en,   // [28]
                                   fault_count,      // [27:24]
                                   fault_pc,         // [23:12]
                                   fault_tile,       // [11:4]
                                   fault_cause};     // [3:0]

            6'h8C: mmio_rdata <= {8'h0,
                                   snap_count,       // [23:16] — actually [7:0] padded
                                   snap_log_size,    // [23:12]
                                   snap_log_base};   // [11:0]

            6'h90: mmio_rdata <= {tid_active_mask,  // [31:16]
                                   shutdown_ready_status, // [14]
                                   switch_active,    // [13]
                                   alloc_conflict,   // [12]
                                   task_count,       // [11:8]
                                   r_target_tid,     // [7:4]
                                   r_active_tid};    // [3:0]

            6'h94: mmio_rdata <= {3'h0,
                                   tid_anchor_valid, // [28]
                                   tid_fault_count,  // [27:24]
                                   tid_pc,           // [23:12]
                                   tid_priority,     // [11:8]
                                   tid_state};       // [7:0]

            6'h98: mmio_rdata <= {22'h0,
                                   tile_allocated,   // [9]
                                   tile_tid,         // [8:5] — padded
                                   r_tile_select};   // [8:0]

            6'h9C: mmio_rdata <= {23'h0, r_tile_select};

            6'hA0: mmio_rdata <= {bw_quota_mbps_status, // [31:16]
                                   bw_tokens_remain};    // [15:0]

            6'hA4: mmio_rdata <= sched_cycles;      // [31:0] TID0-3 fractions

            6'hA8: mmio_rdata <= {13'h0,
                                   omb_flush_done,        // [18]
                                   all_tids_snapshotted,  // [17]
                                   power_off_assert,      // [16]
                                   r_shutdown_timeout_ms, // [15:4]
                                   r_irq_before_power,    // [3]
                                   r_flush_ombs,          // [2]
                                   r_emergency_shutdown_sw,// [1]
                                   r_shutdown_init};      // [0]

            default: mmio_rdata <= 32'hDEADBEEF;    // Unmapped address sentinel

        endcase
    end
end

// =============================================================================
// Output assignments
// =============================================================================

assign mode_sel         = r_mode_sel;
assign noise_headroom   = r_noise_headroom;
assign sat_guard        = r_sat_guard;
assign dark_offset      = r_dark_offset;
assign gain_trim_global = r_gain_trim_global;
assign cal_valid        = r_cal_valid;
assign cal_lock         = r_cal_lock;

assign trim_ch[0]       = r_trim_ch0;
assign trim_ch[1]       = r_trim_ch1;
assign trim_ch[2]       = r_trim_ch2;
assign trim_ch[3]       = r_trim_ch3;
assign trim_ch[4]       = r_trim_ch4;
assign trim_ch[5]       = r_trim_ch5;
assign trim_ch[6]       = r_trim_ch6;
assign trim_ch[7]       = r_trim_ch7;

assign fire             = r_fire_pulse;
assign auto_fire        = r_auto_fire;
assign irq_out          = r_irq_status && r_irq_en;

assign xbar_port_dest[0] = r_xbar_dest0;
assign xbar_port_dest[1] = r_xbar_dest1;
assign xbar_port_dest[2] = r_xbar_dest2;
assign xbar_port_dest[3] = r_xbar_dest3;
assign xbar_port_dest[4] = r_xbar_dest4;
assign xbar_port_dest[5] = r_xbar_dest5;
assign xbar_port_dest[6] = r_xbar_dest6;
assign xbar_port_dest[7] = r_xbar_dest7;
assign xbar_mode         = r_xbar_mode;
assign xbar_update       = r_xbar_update;

// Training mode output assignments
assign train_mode      = r_train_mode;
assign dac_freeze      = r_dac_freeze;
assign sidecar_enable  = r_sidecar_enable;
assign lora_rank       = r_lora_rank;
assign alpha_scaled    = r_alpha_scaled;
assign lora_tile_row   = r_lora_tile_row;
assign lora_tile_col   = r_lora_tile_col;

// Scaled learning output assignments
assign cell_count       = r_cell_count;
assign grad_reduce_en   = r_grad_reduce_en;
assign grad_reduce_fire = r_grad_reduce_fire;
assign auto_grad_reduce = r_auto_grad_reduce;
assign grad_scale       = r_grad_scale;
assign n_spi_buses      = r_n_spi_buses;
assign spi_clk_div      = r_spi_clk_div;

// ISA execution output assignments
assign exec_start       = r_exec_start;
assign exec_stop        = r_exec_stop;
assign exec_reset       = r_exec_reset;
assign exec_step        = r_exec_step;
assign bram_wr_addr     = r_bram_wr_addr;
assign bram_wr_data_lo  = r_bram_wr_data_lo;
assign bram_wr_data_hi  = r_bram_wr_data_hi;
assign bram_wr_en       = r_bram_wr_en;
assign lc_init[0]       = r_lc_init[0];
assign lc_init[1]       = r_lc_init[1];
assign lc_init[2]       = r_lc_init[2];
assign lc_init[3]       = r_lc_init[3];

// Snapshot output assignments
assign rollback_en      = r_rollback_en;
assign rollback_limit   = r_rollback_limit;
assign fault_irq_en     = r_fault_irq_en;

// OS output assignments
assign active_tid            = r_active_tid;
assign target_tid            = r_target_tid;
assign shutdown_init         = r_shutdown_init;
assign emergency_shutdown_sw = r_emergency_shutdown_sw;
assign flush_ombs            = r_flush_ombs;
assign irq_before_power      = r_irq_before_power;
assign shutdown_timeout_ms   = r_shutdown_timeout_ms;
assign tile_select           = r_tile_select;

endmodule
