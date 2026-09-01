// =============================================================================
// GreenCoyote-Bay — AXI-Lite Wrapper
// Project: ODIN_Bridge / Cascaded Optical Reduction Fabric
// Author:  John A. Green
// Date:    June 2026
// =============================================================================
// Wraps greencoyote_pilot_regs.sv with a standard AXI4-Lite slave interface
// compatible with the Alveo U55C Vitis shell AXI-Lite control port.
//
// Fixes vs prior draft:
//   - Address width widened to 8 bits (covers 0x00-0xFC; register map spans 0x00-0xA8)
//   - reg_addr/reg_wdata/reg_write_en/reg_read_en/reg_rdata promoted to module
//     ports (pilot_regs is instantiated at top level, not inside this wrapper)
//   - Removed dead assigns referencing undeclared mmio_*_int nets
//   - Removed conflicting continuous assigns on awready/arready
//   - Separated write and read address registers to avoid multiple drivers
//   - Added proper reset state to read channel state machine
// =============================================================================

module greencoyote_axi_lite_wrapper (
    // AXI4-Lite Slave Interface — connects to Alveo U55C Vitis shell
    input  logic        s_axi_aclk,
    input  logic        s_axi_aresetn,

    // Write address channel
    input  logic [7:0]  s_axi_awaddr,      // 8-bit — covers 0x00 to 0xFC (map spans 0x00-0xA8)
    input  logic        s_axi_awvalid,
    output logic        s_axi_awready,

    // Write data channel
    input  logic [31:0] s_axi_wdata,
    input  logic [3:0]  s_axi_wstrb,       // Byte enables — required by AXI spec
    input  logic        s_axi_wvalid,
    output logic        s_axi_wready,

    // Write response channel
    output logic [1:0]  s_axi_bresp,
    output logic        s_axi_bvalid,
    input  logic        s_axi_bready,

    // Read address channel
    input  logic [7:0]  s_axi_araddr,      // 8-bit — matches write address width
    input  logic        s_axi_arvalid,
    output logic        s_axi_arready,

    // Read data channel
    output logic [31:0] s_axi_rdata,
    output logic [1:0]  s_axi_rresp,
    output logic        s_axi_rvalid,
    input  logic        s_axi_rready,

    // MMIO register bus — to greencoyote_pilot_regs (instantiated at top level)
    output logic [7:0]  reg_addr,
    output logic [31:0] reg_wdata,
    output logic        reg_write_en,
    output logic        reg_read_en,
    input  logic [31:0] reg_rdata,

    // Interrupt output to host CPU via Vitis shell
    input  logic        irq_in,            // From greencoyote_pilot_regs irq_out
    output logic        interrupt

);

// =============================================================================
// Internal signals
// =============================================================================

// Separate write and read address captures — no shared register
logic [7:0]  wr_addr_capture;
logic [7:0]  rd_addr_capture;

// =============================================================================
// Write state machine
// =============================================================================

typedef enum logic [1:0] {
    WR_IDLE   = 2'b00,
    WR_DATA   = 2'b01,
    WR_RESP   = 2'b10
} wr_state_t;

wr_state_t wr_state;

always_ff @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
    if (!s_axi_aresetn) begin
        wr_state        <= WR_IDLE;
        s_axi_awready   <= 1'b1;
        s_axi_wready    <= 1'b0;
        s_axi_bvalid    <= 1'b0;
        s_axi_bresp     <= 2'b00;
        reg_write_en          <= 1'b0;
        wr_addr_capture <= 8'h00;
        reg_wdata       <= 32'h0;
    end else begin
        reg_write_en <= 1'b0;  // Default deassert

        case (wr_state)

            WR_IDLE: begin
                if (s_axi_awvalid && s_axi_awready) begin
                    wr_addr_capture <= s_axi_awaddr;
                    s_axi_awready   <= 1'b0;
                    s_axi_wready    <= 1'b1;
                    wr_state        <= WR_DATA;
                end
            end

            WR_DATA: begin
                if (s_axi_wvalid && s_axi_wready) begin
                    reg_wdata    <= s_axi_wdata;
                    reg_write_en       <= 1'b1;
                    s_axi_wready <= 1'b0;
                    s_axi_bvalid <= 1'b1;
                    s_axi_bresp  <= 2'b00;  // OKAY
                    wr_state     <= WR_RESP;
                end
            end

            WR_RESP: begin
                if (s_axi_bready && s_axi_bvalid) begin
                    s_axi_bvalid  <= 1'b0;
                    s_axi_awready <= 1'b1;
                    wr_state      <= WR_IDLE;
                end
            end

            default: wr_state <= WR_IDLE;

        endcase
    end
end

// =============================================================================
// Read state machine
// =============================================================================

typedef enum logic [1:0] {
    RD_IDLE  = 2'b00,
    RD_DATA  = 2'b01,   // reg_read_en asserted; pilot_regs decodes this cycle
    RD_LATCH = 2'b11,   // pilot_regs has registered mmio_rdata; capture it now
    RD_WAIT  = 2'b10
} rd_state_t;

rd_state_t rd_state;

always_ff @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
    if (!s_axi_aresetn) begin
        rd_state        <= RD_IDLE;
        s_axi_arready   <= 1'b1;
        s_axi_rvalid    <= 1'b0;
        s_axi_rresp     <= 2'b00;
        s_axi_rdata     <= 32'h0;
        reg_read_en          <= 1'b0;
        rd_addr_capture <= 8'h00;
    end else begin
        reg_read_en <= 1'b0;  // Default deassert

        case (rd_state)

            RD_IDLE: begin
                if (s_axi_arvalid && s_axi_arready) begin
                    rd_addr_capture <= s_axi_araddr;
                    s_axi_arready   <= 1'b0;
                    reg_read_en          <= 1'b1;
                    rd_state        <= RD_DATA;
                end
            end

            RD_DATA: begin
                // pilot_regs registers mmio_rdata on this edge (it saw
                // reg_read_en last cycle) — data is not valid until next cycle
                rd_state <= RD_LATCH;
            end

            RD_LATCH: begin
                s_axi_rdata  <= reg_rdata;
                s_axi_rresp  <= 2'b00;   // OKAY
                s_axi_rvalid <= 1'b1;
                rd_state     <= RD_WAIT;
            end

            RD_WAIT: begin
                if (s_axi_rready && s_axi_rvalid) begin
                    s_axi_rvalid  <= 1'b0;
                    s_axi_arready <= 1'b1;
                    rd_state      <= RD_IDLE;
                end
            end

            default: rd_state <= RD_IDLE;

        endcase
    end
end

// =============================================================================
// Address mux — write takes priority when simultaneous
// Read uses captured read address
// =============================================================================

always_comb begin
    if (reg_write_en)
        reg_addr = wr_addr_capture;
    else
        reg_addr = rd_addr_capture;
end

// =============================================================================
// Interrupt passthrough
// =============================================================================

assign interrupt = irq_in;

endmodule
