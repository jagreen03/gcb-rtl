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
    input  wire [(greencoyote_regmap_pkg::ADDR_WIDTH-1):0] mmio_addr,  // width from registers.yaml (map spans 0x00-0xA8)
    input  wire [31:0]  mmio_wdata,
    input  wire         mmio_we,
    input  wire         mmio_re,
    output reg  [31:0]  mmio_rdata,

    // Precision mode outputs to DAC/ADC pipeline
    output wire [2:0]   mode_sel,       // 000=INT4 001=FP4 010=FP8 011=BF16
    output wire [1:0]   noise_headroom,
    output wire [1:0]   sat_guard,

    // Calibration outputs
    output wire [11:0]  dark_offset,
    output wire [11:0]  gain_trim_global,
    output wire         cal_valid,
    output wire         cal_lock,

    // Per-channel gain trim outputs
    output wire [7:0]   trim_ch [0:7],

    // Reduction control outputs
    output wire         fire,            // pulses one cycle
    output wire         auto_fire,
    output wire [1:0]   round_mode,      // REDUCTION_CTRL.ROUND_MODE — BFP rounding (sec 5.2)

    // Reduction status inputs
    input  wire         mode_active,
    input  wire [1:0]   pass_index,
    input  wire [3:0]   queue_depth,
    input  wire         cal_err,
    input  wire         fire_done,
    input  wire         queue_full,

    // BFP scale status inputs (BLK_SCALE_STATUS 0xAC)
    input  wire [4:0]   blk_exp_last,    // shared block exponent, last fire
    input  wire         blk_scale_clamp, // sticky BFP-window clamp
    input  wire [3:0]   lane_bias_n,     // active lane count latched at fire

    // Interrupt output to host CPU
    output wire         irq_out,

    // Crossbar routing outputs to optical switch
    // Each port_dest field: 000-110=route to GPU N, 111=broadcast, 110=reduce, 101=pipeline-next
    output wire [2:0]   xbar_port_dest [0:7],  // Destination per input port
    output wire [1:0]   xbar_mode,             // 00=tensor 01=pipeline 10=moe 11=custom
    output wire         xbar_update,            // Pulses one cycle when routing changes
    input  wire         xbar_ready,             // Switch confirms new routing applied

    // Training mode outputs to Learning Appliance
    output wire         train_mode,             // 0=inference 1=LoRA adaptation enabled
    output wire         dac_freeze,             // 1=freeze sidecar DACs during forward pass
    output wire         sidecar_enable,         // 1=sidecar outputs active in MMI combiner
    output wire [2:0]   lora_rank,              // Encoded rank
    output wire [15:0]  alpha_scaled,           // α/r as Q8.8 fixed-point
    output wire [15:0]  lora_tile_row,          // Current sidecar DAC row
    output wire [15:0]  lora_tile_col,          // Current sidecar DAC column

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
    output wire [9:0]   cell_count,             // Total Training Cells in fabric
    output wire         grad_reduce_en,         // Enable optical gradient all-reduce
    output wire         grad_reduce_fire,       // Trigger gradient reduction
    output wire         auto_grad_reduce,       // Fire automatically when all cells ready
    output wire [23:0]  grad_scale,             // Global gradient scaling Q8.16
    output wire [1:0]   n_spi_buses,            // Parallel SPI buses per cell
    output wire [15:0]  spi_clk_div,            // SPI clock divider

    // ISA execution outputs
    output wire         exec_start,             // Begin program execution
    output wire         exec_stop,              // Halt after current instruction
    output wire         exec_reset,             // Reset PC to 0
    output wire         exec_step,              // Single-step mode
    output wire [11:0]  bram_wr_addr,           // BRAM write address
    output wire [31:0]  bram_wr_data_lo,        // BRAM write data low 32 bits
    output wire [31:0]  bram_wr_data_hi,        // BRAM write data high 32 bits
    output wire         bram_wr_en,             // BRAM write enable pulse
    output wire [15:0]  lc_init [0:3],          // Loop counter initial values

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
    output wire         rollback_en,            // Enable automatic rollback
    output wire [7:0]   rollback_limit,         // Max rollbacks before systemic fault
    output wire         fault_irq_en,           // IRQ on any fault

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
    output wire [3:0]   active_tid,             // Currently selected TID for status reads
    output wire [3:0]   target_tid,             // TID for next CONTEXT_SWITCH
    output wire         shutdown_init,          // Initiate ordered shutdown
    output wire         emergency_shutdown_sw,  // Software emergency shutdown
    output wire         flush_ombs,             // Include OMB flush in shutdown
    output wire         irq_before_power,       // IRQ before POWER_OFF
    output wire [11:0]  shutdown_timeout_ms,    // Timeout for TID snapshot collection
    output wire [8:0]   tile_select,            // Tile index for allocation map query

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

// Generated address map / constants (registers.yaml -> regen.py)
import greencoyote_regmap_pkg::*;

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
reg [1:0]   r_round_mode;      // [12:11] BFP rounding: 00 trunc 01 rne 10 stochastic

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
reg         queue_full_prev;   // For rising-edge AUTO_FIRE detection

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
        r_round_mode        <= 2'b01;   // RNE default (registers.yaml)
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
        queue_full_prev     <= 1'b0;
    end else begin

        // Auto-clear FIRE pulse after one cycle
        r_fire_pulse       <= 1'b0;
        r_bram_wr_en       <= 1'b0;   // BRAM write strobe — one cycle (set on a 0x6C write)
        r_grad_reduce_fire <= 1'b0;
        // Auto-clear crossbar update strobe after one cycle
        r_xbar_update <= 1'b0;
        // EXEC_START/STOP/RESET/STEP (0x60) — one-cycle strobes, not level registers
        r_exec_start  <= 1'b0;
        r_exec_stop   <= 1'b0;
        r_exec_reset  <= 1'b0;
        r_exec_step   <= 1'b0;

        // AUTO_GRAD_REDUCE — fire gradient reduction when all cells ready
        if (r_auto_grad_reduce && r_grad_reduce_en &&
            (cells_ready >= r_cell_count) && !grad_reduce_done)
            r_grad_reduce_fire <= 1'b1;

        if (mmio_we) begin
            case (mmio_addr)

                // 0x00 Precision Mode Configuration
                ADDR_PRECISION_MODE: begin
                    r_mode_sel       <= mmio_wdata[2:0];
                    r_noise_headroom <= mmio_wdata[4:3];
                    r_sat_guard      <= mmio_wdata[6:5];
                end

                // 0x04 Global Calibration
                ADDR_GLOBAL_CAL: begin
                    // Payload is blocked only while the lock is held AND this
                    // write keeps it held. A write that clears CAL_LOCK[25] also
                    // lands its own calibration payload (unlock-and-update).
                    if (!r_cal_lock || !mmio_wdata[25]) begin
                        r_dark_offset      <= mmio_wdata[11:0];
                        r_gain_trim_global <= mmio_wdata[23:12];
                        r_cal_valid        <= mmio_wdata[24];
                    end
                    r_cal_lock <= mmio_wdata[25];  // CAL_LOCK always writable
                end

                // 0x08 Channel Gain Trim 0-3
                ADDR_CH_GAIN_TRIM_LO: begin
                    r_trim_ch0 <= mmio_wdata[7:0];
                    r_trim_ch1 <= mmio_wdata[15:8];
                    r_trim_ch2 <= mmio_wdata[23:16];
                    r_trim_ch3 <= mmio_wdata[31:24];
                end

                // 0x0C Channel Gain Trim 4-7
                ADDR_CH_GAIN_TRIM_HI: begin
                    r_trim_ch4 <= mmio_wdata[7:0];
                    r_trim_ch5 <= mmio_wdata[15:8];
                    r_trim_ch6 <= mmio_wdata[23:16];
                    r_trim_ch7 <= mmio_wdata[31:24];
                end

                // 0x10 Reduction Control
                ADDR_REDUCTION_CTRL: begin
                    if (mmio_wdata[0])    // FIRE bit — self-clearing
                        r_fire_pulse <= 1'b1;
                    r_auto_fire  <= mmio_wdata[10];
                    r_round_mode <= mmio_wdata[12:11];
                end

                // 0x14 Interrupt Control
                ADDR_IRQ_CTRL: begin
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
                ADDR_XBAR_ROUTE_LO: begin
                    r_xbar_dest0  <= mmio_wdata[2:0];
                    r_xbar_dest1  <= mmio_wdata[5:3];
                    r_xbar_dest2  <= mmio_wdata[8:6];
                    r_xbar_dest3  <= mmio_wdata[11:9];
                    r_xbar_update <= 1'b1;  // Strobe switch to apply new routing
                end

                // 0x1C Crossbar Routing High — ports 4-7
                ADDR_XBAR_ROUTE_HI: begin
                    r_xbar_dest4  <= mmio_wdata[2:0];
                    r_xbar_dest5  <= mmio_wdata[5:3];
                    r_xbar_dest6  <= mmio_wdata[8:6];
                    r_xbar_dest7  <= mmio_wdata[11:9];
                    r_xbar_update <= 1'b1;
                end

                // 0x20 Crossbar Mode and Status
                // [1:0]=XBAR_MODE 00=tensor 01=pipeline 10=moe 11=custom
                ADDR_XBAR_MODE_STATUS: begin
                    r_xbar_mode   <= mmio_wdata[1:0];
                    r_xbar_update <= 1'b1;
                end

                // 0x24 Training Mode Control
                // [0]=TRAIN_MODE [1]=DAC_FREEZE [4]=SIDECAR_ENABLE
                // [7:5]=LORA_RANK [23:8]=ALPHA_SCALED
                ADDR_TRAIN_CTRL: begin
                    r_train_mode     <= mmio_wdata[0];
                    r_dac_freeze     <= mmio_wdata[1];
                    r_sidecar_enable <= mmio_wdata[4];
                    r_lora_rank      <= mmio_wdata[7:5];
                    r_alpha_scaled   <= mmio_wdata[23:8];
                end

                // 0x2C LoRA Tile Address
                ADDR_LORA_TILE_ADDR: begin
                    r_lora_tile_row <= mmio_wdata[15:0];
                    r_lora_tile_col <= mmio_wdata[31:16];
                end

                // 0x30 Cell Count (host writes total cell count at init)
                ADDR_CELL_COUNT_SYNC: begin
                    r_cell_count <= mmio_wdata[9:0];
                end

                // 0x34 Gradient All-Reduce Control
                // [0]=GRAD_REDUCE_EN [1]=GRAD_REDUCE_FIRE(self-clear)
                // [2]=AUTO_GRAD_REDUCE [31:8]=GRAD_SCALE Q8.16
                ADDR_GRAD_REDUCE_CTRL: begin
                    r_grad_reduce_en   <= mmio_wdata[0];
                    if (mmio_wdata[1])
                        r_grad_reduce_fire <= 1'b1; // Self-clearing
                    r_auto_grad_reduce <= mmio_wdata[2];
                    r_grad_scale       <= mmio_wdata[31:8];
                end

                // 0x38 SPI Bus Configuration
                // [1:0]=N_SPI_BUSES [23:8]=SPI_CLK_DIV
                ADDR_SPI_CFG: begin
                    r_n_spi_buses  <= mmio_wdata[1:0];
                    r_spi_clk_div  <= mmio_wdata[23:8];
                end

                // 0x60 Execution Control
                // [0]=EXEC_START [1]=EXEC_STOP [2]=EXEC_RESET [3]=EXEC_STEP
                ADDR_EXEC_CTRL: begin
                    r_exec_start <= mmio_wdata[0];
                    r_exec_stop  <= mmio_wdata[1];
                    r_exec_reset <= mmio_wdata[2];
                    r_exec_step  <= mmio_wdata[3];
                end

                // 0x64 BRAM Write Address
                ADDR_BRAM_WR_ADDR: begin
                    r_bram_wr_addr <= mmio_wdata[11:0];
                    r_bram_wr_en   <= 1'b0; // Clear — wait for 0x6C write
                end

                // 0x68 BRAM Write Data Low
                ADDR_BRAM_WR_DATA_LO: begin
                    r_bram_wr_data_lo <= mmio_wdata;
                    r_bram_wr_en      <= 1'b0;
                end

                // 0x6C BRAM Write Data High — triggers BRAM write
                ADDR_BRAM_WR_DATA_HI: begin
                    r_bram_wr_data_hi <= mmio_wdata;
                    r_bram_wr_en      <= 1'b1; // Pulse — write assembled instruction
                    r_bram_wr_addr    <= r_bram_wr_addr + 1; // Auto-increment
                end

                // 0x70 Loop Counter Load Low (LC0, LC1)
                ADDR_LC_LOAD_LO: begin
                    r_lc_init[0] <= mmio_wdata[15:0];
                    r_lc_init[1] <= mmio_wdata[31:16];
                end

                // 0x74 Loop Counter Load High (LC2, LC3)
                ADDR_LC_LOAD_HI: begin
                    r_lc_init[2] <= mmio_wdata[15:0];
                    r_lc_init[3] <= mmio_wdata[31:16];
                end

                // 0x84 Rollback Control
                // [29]=ROLLBACK_EN [15:8]=ROLLBACK_LIMIT [28]=FAULT_IRQ_EN
                ADDR_ROLLBACK_CTRL: begin
                    r_rollback_limit <= mmio_wdata[15:8];
                    r_rollback_en    <= mmio_wdata[29];
                    r_fault_irq_en   <= mmio_wdata[28];
                end

                // 0x90 Task Allocation Control
                // [3:0]=ACTIVE_TID [7:4]=TARGET_TID [15]=SHUTDOWN_ACK
                ADDR_TASK_ALLOC_CTRL: begin
                    r_active_tid <= mmio_wdata[3:0];
                    r_target_tid <= mmio_wdata[7:4];
                end

                // 0x98 Tile Select (for allocation map query)
                ADDR_TILE_SELECT: begin
                    r_tile_select <= mmio_wdata[8:0];
                end

                // 0xA8 Shutdown Control
                // [0]=SHUTDOWN_INIT [1]=EMERGENCY [2]=FLUSH_OMBS
                // [3]=IRQ_BEFORE_POWER [15:4]=SHUTDOWN_TIMEOUT_MS
                ADDR_SHUTDOWN_CTRL: begin
                    r_shutdown_init        <= mmio_wdata[0];
                    r_emergency_shutdown_sw <= mmio_wdata[1];
                    r_flush_ombs           <= mmio_wdata[2];
                    r_irq_before_power     <= mmio_wdata[3];
                    r_shutdown_timeout_ms  <= mmio_wdata[15:4];
                end

            endcase
        end

        // AUTO_FIRE logic — trigger on the rising edge of queue_full when
        // enabled. Edge (not level) so a buffer set that stays full does not
        // re-arm a fresh reduction every cycle after the previous one completes.
        queue_full_prev <= queue_full;
        if (r_auto_fire && queue_full && !queue_full_prev && !mode_active)
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

            ADDR_PRECISION_MODE: mmio_rdata <= {24'h0,
                                   1'b0,
                                   r_sat_guard,
                                   r_noise_headroom,
                                   r_mode_sel};

            ADDR_GLOBAL_CAL: mmio_rdata <= {6'h0,
                                   r_cal_lock,
                                   r_cal_valid,
                                   r_gain_trim_global,
                                   r_dark_offset};

            ADDR_CH_GAIN_TRIM_LO: mmio_rdata <= {r_trim_ch3,
                                   r_trim_ch2,
                                   r_trim_ch1,
                                   r_trim_ch0};

            ADDR_CH_GAIN_TRIM_HI: mmio_rdata <= {r_trim_ch7,
                                   r_trim_ch6,
                                   r_trim_ch5,
                                   r_trim_ch4};

            ADDR_REDUCTION_CTRL: mmio_rdata <= {19'h0,
                                   r_round_mode,     // [12:11]
                                   r_auto_fire,      // [10]
                                   fire_done,        // [9]
                                   cal_err,          // [8]
                                   queue_depth,      // [7:4]
                                   pass_index,       // [3:2]
                                   mode_active,      // [1]
                                   1'b0};            // [0] FIRE reads as 0 (self-clearing)

            ADDR_BLK_SCALE_STATUS: mmio_rdata <= {22'h0,
                                   lane_bias_n,      // [9:6]
                                   blk_scale_clamp,  // [5]
                                   blk_exp_last};    // [4:0]

            ADDR_IRQ_CTRL: mmio_rdata <= {22'h0,
                                   r_irq_status,     // [8] read only
                                   3'h0,
                                   r_irq_pass_done_en,
                                   r_irq_queue_full_en,
                                   r_irq_cal_err_en,
                                   r_irq_fire_done_en,
                                   r_irq_en};

            ADDR_XBAR_ROUTE_LO: mmio_rdata <= {20'h0,
                                   r_xbar_dest3,     // [11:9]
                                   r_xbar_dest2,     // [8:6]
                                   r_xbar_dest1,     // [5:3]
                                   r_xbar_dest0};    // [2:0]

            ADDR_XBAR_ROUTE_HI: mmio_rdata <= {20'h0,
                                   r_xbar_dest7,     // [11:9]
                                   r_xbar_dest6,     // [8:6]
                                   r_xbar_dest5,     // [5:3]
                                   r_xbar_dest4};    // [2:0]

            ADDR_XBAR_MODE_STATUS: mmio_rdata <= {29'h0,
                                   xbar_ready,       // [2] switch ready status input
                                   r_xbar_mode};     // [1:0]

            ADDR_TRAIN_CTRL: mmio_rdata <= {8'h0,
                                   r_alpha_scaled,   // [23:8]
                                   r_lora_rank,      // [7:5]
                                   1'b0,             // [4] SIDECAR_ENABLE readback
                                   update_active,    // [3]
                                   update_pending,   // [2]
                                   r_dac_freeze,     // [1]
                                   r_train_mode};    // [0]

            ADDR_GRAD_UPDATE_STATUS: mmio_rdata <= {13'h0,
                                   checksum_fail,    // [18]
                                   checksum_pass,    // [17]
                                   update_done,      // [16]
                                   channels_updated};// [15:0]

            ADDR_LORA_TILE_ADDR: mmio_rdata <= {r_lora_tile_col,  // [31:16]
                                   r_lora_tile_row}; // [15:0]

            ADDR_CELL_COUNT_SYNC: mmio_rdata <= {11'h0,
                                   grad_reduce_done, // [21]
                                   1'b0,             // [20] ALL_CELLS_READY computed
                                   cells_ready,      // [19:10]
                                   r_cell_count};    // [9:0]

            ADDR_GRAD_REDUCE_CTRL: mmio_rdata <= {r_grad_scale,      // [31:8]
                                   5'h0,
                                   r_auto_grad_reduce,// [2]
                                   1'b0,             // [1] self-clearing
                                   r_grad_reduce_en};// [0]

            ADDR_SPI_CFG: mmio_rdata <= {8'h0,
                                   r_spi_clk_div,    // [23:8]
                                   6'h0,
                                   r_n_spi_buses};   // [1:0]

            ADDR_EXEC_CTRL: mmio_rdata <= {exec_opcode,       // [31:24]
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

            ADDR_BRAM_WR_ADDR: mmio_rdata <= {20'h0, r_bram_wr_addr};

            ADDR_BRAM_WR_DATA_LO: mmio_rdata <= r_bram_wr_data_lo;

            ADDR_BRAM_WR_DATA_HI: mmio_rdata <= r_bram_wr_data_hi;

            ADDR_LC_LOAD_LO: mmio_rdata <= {r_lc_init[1], r_lc_init[0]};

            ADDR_LC_LOAD_HI: mmio_rdata <= {r_lc_init[3], r_lc_init[2]};

            ADDR_SYNC_STATUS: mmio_rdata <= {14'h0,
                                   sync_timeout,     // [17]
                                   1'b0,
                                   sync_pending};    // [15:0]

            ADDR_EXEC_ERR_LOG: mmio_rdata <= {8'h0,
                                   err_cause,        // [27:24] — padded in 31:28
                                   err_opcode,       // [19:12]
                                   err_pc};          // [11:0]

            ADDR_SNAPSHOT_STATUS: mmio_rdata <= {4'h0,
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

            ADDR_ROLLBACK_CTRL: mmio_rdata <= {2'h0,
                                   r_rollback_en,    // [29]
                                   r_fault_irq_en,   // [28]
                                   snap_pc_last,     // [27:16]
                                   r_rollback_limit, // [15:8]
                                   8'h0};            // [7:0] rollback_count from interp

            ADDR_FAULT_LOG: mmio_rdata <= {3'h0,
                                   r_fault_irq_en,   // [28]
                                   fault_count,      // [27:24]
                                   fault_pc,         // [23:12]
                                   fault_tile,       // [11:4]
                                   fault_cause};     // [3:0]

            ADDR_SNAP_LOG_PTR: mmio_rdata <= {8'h0,
                                   snap_count,       // [23:16] — actually [7:0] padded
                                   snap_log_size,    // [23:12]
                                   snap_log_base};   // [11:0]

            ADDR_TASK_ALLOC_CTRL: mmio_rdata <= {tid_active_mask,       // [31:16]
                                   1'b0,                  // [15] SHUTDOWN_ACK write-only, reads 0
                                   shutdown_ready_status, // [14]
                                   switch_active,         // [13]
                                   alloc_conflict,        // [12]
                                   task_count,            // [11:8]
                                   r_target_tid,          // [7:4]
                                   r_active_tid};         // [3:0]

            ADDR_TID_STATUS: mmio_rdata <= {3'h0,
                                   tid_anchor_valid, // [28]
                                   tid_fault_count,  // [27:24]
                                   tid_pc,           // [23:12]
                                   tid_priority,     // [11:8]
                                   tid_state};       // [7:0]

            ADDR_TILE_ALLOC_MAP: mmio_rdata <= {18'h0,           // [31:14]
                                   tile_allocated,  // [13]
                                   tile_tid,        // [12:9]
                                   r_tile_select};  // [8:0]

            ADDR_TILE_SELECT: mmio_rdata <= {23'h0, r_tile_select};

            ADDR_RATE_LIMIT_STATUS: mmio_rdata <= {bw_quota_mbps_status, // [31:16]
                                   bw_tokens_remain};    // [15:0]

            ADDR_SCHED_STATS: mmio_rdata <= sched_cycles;      // [31:0] TID0-3 fractions

            ADDR_SHUTDOWN_CTRL: mmio_rdata <= {13'h0,
                                   omb_flush_done,        // [18]
                                   all_tids_snapshotted,  // [17]
                                   power_off_assert,      // [16]
                                   r_shutdown_timeout_ms, // [15:4]
                                   r_irq_before_power,    // [3]
                                   r_flush_ombs,          // [2]
                                   r_emergency_shutdown_sw,// [1]
                                   r_shutdown_init};      // [0]

            default: mmio_rdata <= UNMAPPED_READ;   // Unmapped address sentinel (registers.yaml)

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
assign round_mode       = r_round_mode;
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
