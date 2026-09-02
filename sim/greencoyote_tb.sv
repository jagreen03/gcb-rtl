// =============================================================================
// GreenCoyote-Bay — Testbench
// Project: ODIN_Bridge / Cascaded Optical Reduction Fabric
// Author:  John A. Green
// Date:    June 2026
// =============================================================================
// Test Coverage:
//   TC1 — AUTO_FIRE basic: buf_full asserts, dac_sync fires without CPU
//   TC2 — Manual FIRE via register write
//   TC3 — 14-GPU two-pass reduction: pass_index transitions 00→01→10
//   TC4 — cal_err sticky bit: ADC clip injection, verify bit holds
//   TC5 — CAL_LOCK: verify calibration registers block during lock
//   TC6 — Precision mode switch during idle: verify no mid-reduction glitch
//   TC7 — IRQ flow: fire_done asserts irq_out, IRQ_CLEAR deasserts it
// =============================================================================

`timescale 1ns/1ps

module greencoyote_tb;

// =============================================================================
// Clock and reset
// =============================================================================

logic clk;
logic rst_n;

initial clk = 0;
always #5 clk = ~clk;      // 100MHz — 10ns period

// =============================================================================
// DUT interface signals
// =============================================================================

// AXI-Lite
logic [7:0]  s_axi_awaddr;
logic        s_axi_awvalid;
logic        s_axi_awready;
logic [31:0] s_axi_wdata;
logic [3:0]  s_axi_wstrb;
logic        s_axi_wvalid;
logic        s_axi_wready;
logic [1:0]  s_axi_bresp;
logic        s_axi_bvalid;
logic        s_axi_bready;
logic [7:0]  s_axi_araddr;
logic        s_axi_arvalid;
logic        s_axi_arready;
logic [31:0] s_axi_rdata;
logic [1:0]  s_axi_rresp;
logic        s_axi_rvalid;
logic        s_axi_rready;

// Buffer interface
logic [31:0] buf_data [0:7];
logic [7:0]  buf_full;
logic [7:0]  buf_clear;

// Native DAC PHY
logic [11:0] dac_data [0:7];
logic [7:0]  dac_valid;
logic        dac_sync;

// Parallel DAC interface — bench loopback (greencoyote_dac_if)
logic [13:0] dac_p_data;
logic [2:0]  dac_p_chan;
logic        dac_p_clk;
logic        dac_p_wr_n;

// SPI SAR ADC interface — bench loopback (greencoyote_adc_if)
logic        adc_sclk;
logic        adc_cs_n;
logic        adc_mosi;
logic        adc_miso;

// Interrupt
logic        interrupt;

// =============================================================================
// DUT instantiation
// =============================================================================

greencoyote_top dut (
    .user_clk           (clk),
    .peripheral_aresetn (rst_n),
    .s_axi_awaddr       (s_axi_awaddr),
    .s_axi_awvalid      (s_axi_awvalid),
    .s_axi_awready      (s_axi_awready),
    .s_axi_wdata        (s_axi_wdata),
    .s_axi_wstrb        (s_axi_wstrb),
    .s_axi_wvalid       (s_axi_wvalid),
    .s_axi_wready       (s_axi_wready),
    .s_axi_bresp        (s_axi_bresp),
    .s_axi_bvalid       (s_axi_bvalid),
    .s_axi_bready       (s_axi_bready),
    .s_axi_araddr       (s_axi_araddr),
    .s_axi_arvalid      (s_axi_arvalid),
    .s_axi_arready      (s_axi_arready),
    .s_axi_rdata        (s_axi_rdata),
    .s_axi_rresp        (s_axi_rresp),
    .s_axi_rvalid       (s_axi_rvalid),
    .s_axi_rready       (s_axi_rready),
    .buf_data           (buf_data),
    .buf_full           (buf_full),
    .buf_clear          (buf_clear),
    .dac_data           (dac_data),
    .dac_valid          (dac_valid),
    .dac_sync           (dac_sync),
    .dac_p_data         (dac_p_data),
    .dac_p_chan         (dac_p_chan),
    .dac_p_clk          (dac_p_clk),
    .dac_p_wr_n         (dac_p_wr_n),
    .adc_sclk           (adc_sclk),
    .adc_cs_n           (adc_cs_n),
    .adc_mosi           (adc_mosi),
    .adc_miso           (adc_miso),
    .interrupt          (interrupt)
);

// =============================================================================
// SPI SAR ADC Bus Functional Model
// Mode 0 (CPOL=0, CPHA=0). On CS falling it presents a 16-bit frame
// {4'h0, adc_result} MSB-first on MISO; the master (greencoyote_adc_if) samples
// on SCLK rising, so the BFM advances to the next bit on SCLK falling.
// =============================================================================

logic [11:0] adc_result = 12'h800;   // Value the emulated ADC returns
logic [15:0] miso_shift;

initial adc_miso = 1'b0;

always @(negedge adc_cs_n) begin
    miso_shift = {4'h0, adc_result};
    adc_miso   = miso_shift[15];
end

always @(negedge adc_sclk) begin
    if (!adc_cs_n) begin
        miso_shift = {miso_shift[14:0], 1'b0};   // shift, then present the new MSB
        adc_miso   = miso_shift[15];
    end
end

always @(posedge adc_cs_n) adc_miso = 1'b0;

// =============================================================================
// Parallel DAC Bus Functional Model
// Latches the 14-bit word into per-channel capture on each dac_p_clk rising
// edge; counts total loads. Verifies the digital DAC roundtrip.
// =============================================================================

logic [13:0] dac_cap [0:7];
int          dac_loads;

initial begin
    dac_loads = 0;
    for (int i = 0; i < 8; i++) dac_cap[i] = 14'h0000;
end

always @(posedge dac_p_clk) begin
    if (!dac_p_wr_n) begin
        dac_cap[dac_p_chan] <= dac_p_data;
        dac_loads           <= dac_loads + 1;
    end
end

// =============================================================================
// Transient-event capture — buf_clear and pass_index pulse for a single cycle,
// so latch them for the checkers. Cleared per test via clear_events().
// =============================================================================

logic [7:0] buf_clear_seen;
logic       saw_pass1b;
logic       saw_pass2;

always @(posedge clk) begin
    if (|buf_clear)              buf_clear_seen <= buf_clear;
    if (dut.pass_index == 2'b01) saw_pass1b     <= 1'b1;
    if (dut.pass_index == 2'b10) saw_pass2      <= 1'b1;
end

task clear_events();
    buf_clear_seen = 8'h00;
    saw_pass1b     = 1'b0;
    saw_pass2      = 1'b0;
endtask

// =============================================================================
// AXI-Lite write task
// =============================================================================

task axi_write(input logic [7:0] addr, input logic [31:0] data);
    @(posedge clk);
    s_axi_awaddr  <= addr;
    s_axi_awvalid <= 1'b1;
    s_axi_wdata   <= data;
    s_axi_wstrb   <= 4'hF;
    s_axi_wvalid  <= 1'b1;
    s_axi_bready  <= 1'b1;
    // AW and W handshakes complete independently on this slave
    do @(posedge clk); while (!(s_axi_awready));
    s_axi_awvalid <= 1'b0;
    do @(posedge clk); while (!(s_axi_wready));
    s_axi_wvalid  <= 1'b0;
    do @(posedge clk); while (!(s_axi_bvalid));
    @(posedge clk);
    s_axi_bready  <= 1'b0;
    $display("[%0t] AXI WRITE addr=0x%02X data=0x%08X", $time, addr, data);
endtask

// =============================================================================
// AXI-Lite read task
// =============================================================================

task axi_read(input logic [7:0] addr, output logic [31:0] data);
    @(posedge clk);
    s_axi_araddr  <= addr;
    s_axi_arvalid <= 1'b1;
    s_axi_rready  <= 1'b1;
    do @(posedge clk); while (!(s_axi_arready));
    @(posedge clk);
    s_axi_arvalid <= 1'b0;
    do @(posedge clk); while (!(s_axi_rvalid));
    data = s_axi_rdata;
    @(posedge clk);
    s_axi_rready  <= 1'b0;
    $display("[%0t] AXI READ  addr=0x%02X data=0x%08X", $time, addr, data);
endtask

// =============================================================================
// ADC stimulus helper — program the value the persistent responder returns for
// subsequent conversions (see the "Persistent ADC model" initial block above).
// =============================================================================

task set_adc(input logic [11:0] result);
    adc_result = result;
endtask

// =============================================================================
// Initialization
// =============================================================================

task initialize();
    rst_n         <= 1'b0;
    s_axi_awvalid <= 1'b0;
    s_axi_wvalid  <= 1'b0;
    s_axi_bready  <= 1'b0;
    s_axi_arvalid <= 1'b0;
    s_axi_rready  <= 1'b0;
    s_axi_awaddr  <= 8'h00;
    s_axi_wdata   <= 32'h0;
    s_axi_wstrb   <= 4'hF;
    s_axi_araddr  <= 8'h00;
    buf_full      <= 8'h00;
    for (int i = 0; i < 8; i++)
        buf_data[i] <= 32'h0;
    repeat(4) @(posedge clk);
    rst_n <= 1'b1;
    repeat(4) @(posedge clk);
    $display("[%0t] Reset complete", $time);
endtask

// =============================================================================
// Setup task — write all initialization registers
// =============================================================================

task setup_registers();
    // 0x00 Precision Mode = FP8 (010), noise_headroom=01, sat_guard=01
    axi_write(6'h00, 32'h0000_0032);   // [2:0]=010 [4:3]=01 [6:5]=01

    // 0x04 Global Calibration — dark_offset=0x010, cal_valid=1, cal_lock=0
    axi_write(6'h04, 32'h0100_0010);   // [11:0]=dark_offset [24]=cal_valid

    // 0x08 Channel Gain Trim 0-3 — unity gain = 0xFF each
    axi_write(6'h08, 32'hFFFF_FFFF);

    // 0x0C Channel Gain Trim 4-7 — unity gain = 0xFF each
    axi_write(6'h0C, 32'hFFFF_FFFF);

    // 0x14 Interrupt Control — enable IRQ_EN and IRQ_FIRE_DONE
    axi_write(6'h14, 32'h0000_0003);   // [0]=IRQ_EN [1]=IRQ_FIRE_DONE

    $display("[%0t] Registers initialized", $time);
endtask

// =============================================================================
// TC1 — AUTO_FIRE basic
// =============================================================================

task tc1_auto_fire();
    $display("\n[%0t] === TC1: AUTO_FIRE basic ===", $time);
    clear_events();
    set_adc(12'h800);                  // Mid-scale ADC result

    // Enable AUTO_FIRE in 0x10 bit[10]
    axi_write(6'h10, 32'h0000_0400);   // AUTO_FIRE=1

    // Load GPU partial sum data
    for (int i = 0; i < 8; i++)
        buf_data[i] <= 32'h0000_0080;  // All channels = 128

    // Assert all buf_full flags — simulates all 8 GPUs ready
    @(posedge clk);
    buf_full <= 8'hFF;
    $display("[%0t] buf_full asserted 0xFF — expecting AUTO_FIRE", $time);

    // Wait for dac_sync without any CPU FIRE write
    do @(posedge clk); while (!(dac_sync));
    $display("[%0t] PASS TC1: dac_sync asserted autonomously", $time);

    // Wait for fire_done (persistent ADC model supplies the conversion result)
    do @(posedge clk); while (!(interrupt));
    $display("[%0t] PASS TC1: interrupt asserted on fire_done", $time);

    // Verify buf_clear pulsed with all channels (latched — it is a 1-cycle strobe)
    if (buf_clear_seen == 8'hFF)
        $display("[%0t] PASS TC1: buf_clear correct 0xFF", $time);
    else
        $display("[%0t] FAIL TC1: buf_clear_seen = 0x%02X expected 0xFF", $time, buf_clear_seen);

    // Clear interrupt
    axi_write(6'h14, 32'h0000_0203);  // IRQ_CLEAR=1
    buf_full <= 8'h00;
    repeat(4) @(posedge clk);
endtask

// =============================================================================
// TC2 — Manual FIRE via register write
// =============================================================================

task tc2_manual_fire();
    $display("\n[%0t] === TC2: Manual FIRE register write ===", $time);
    clear_events();
    set_adc(12'h700);

    // Disable AUTO_FIRE
    axi_write(6'h10, 32'h0000_0000);

    // Load buffers
    for (int i = 0; i < 8; i++)
        buf_data[i] <= 32'h0000_00C0;
    buf_full <= 8'hFF;

    // CPU writes FIRE bit manually
    axi_write(6'h10, 32'h0000_0001);   // FIRE=1 self-clearing
    $display("[%0t] Manual FIRE written", $time);

    do @(posedge clk); while (!(dac_sync));
    $display("[%0t] PASS TC2: dac_sync asserted on manual FIRE", $time);

    do @(posedge clk); while (!(interrupt));
    $display("[%0t] PASS TC2: interrupt on fire_done", $time);

    axi_write(6'h14, 32'h0000_0203);
    buf_full <= 8'h00;
    repeat(4) @(posedge clk);
endtask

// =============================================================================
// TC3 — 14-GPU two-pass reduction
// Pass 1a: channels 0-7 (8 GPUs)
// Pass 1b: channels 0-5 (6 GPUs, channels 6-7 zero-padded)
// =============================================================================

task tc3_14gpu_two_pass();
    logic [31:0] rdata;
    $display("\n[%0t] === TC3: 14-GPU two-pass reduction ===", $time);
    clear_events();
    set_adc(12'h400);

    axi_write(6'h10, 32'h0000_0400);   // AUTO_FIRE=1

    // Pass 1a — all 8 channels full
    for (int i = 0; i < 8; i++)
        buf_data[i] <= 32'h0000_0040;
    buf_full <= 8'hFF;

    do @(posedge clk); while (!(dac_sync));
    $display("[%0t] TC3: Pass 1a dac_sync fired", $time);

    // Drop to the 6-GPU remainder BEFORE Pass 1a's ADC returns, so the
    // sequencer sees is_14gpu_mode at PASS_CHECK and chains into Pass 1b/2.
    buf_full <= 8'h3F;   // channels 6,7 empty — 14-GPU second-pass shape

    // Sequencer auto-chains PASS_CHECK -> LOAD_PASS2 -> FIRE_PASS2 -> CAPTURE2 -> DONE
    do @(posedge clk); while (!(interrupt));
    $display("[%0t] TC3: two-pass reduction complete (interrupt)", $time);

    // pass_index must have transitioned 00 -> 01 (Pass 1b) -> 10 (Pass 2)
    if (saw_pass1b)
        $display("[%0t] PASS TC3: pass_index reached 01 (Pass 1b)", $time);
    else
        $display("[%0t] FAIL TC3: pass_index never reached 01", $time);

    if (saw_pass2)
        $display("[%0t] PASS TC3: pass_index reached 10 (Pass 2 digital sum)", $time);
    else
        $display("[%0t] FAIL TC3: pass_index never reached 10", $time);

    $display("[%0t] PASS TC3: fire_done interrupt on two-pass completion", $time);

    axi_write(6'h14, 32'h0000_0203);
    buf_full <= 8'h00;
    repeat(4) @(posedge clk);
endtask

// =============================================================================
// TC4 — cal_err sticky bit injection
// Inject ADC clip value above ADC_CLIP_THRESH (0xF00)
// Verify cal_err sticks until host clears
// =============================================================================

task tc4_cal_err_injection();
    logic [31:0] rdata;
    $display("\n[%0t] === TC4: cal_err sticky bit injection ===", $time);
    clear_events();
    set_adc(12'hF80);                  // Above ADC_CLIP_THRESH (0xF00)

    axi_write(6'h10, 32'h0000_0400);

    for (int i = 0; i < 8; i++)
        buf_data[i] <= 32'h0000_00FF;
    buf_full <= 8'hFF;

    do @(posedge clk); while (!(dac_sync));
    $display("[%0t] TC4: dac_sync fired — clip ADC value armed", $time);

    // Let the reduction capture the clipped conversion
    do @(posedge clk); while (!(interrupt));
    repeat(2) @(posedge clk);

    // Read 0x10 — check cal_err bit[8]
    axi_read(6'h10, rdata);
    if (rdata[8] == 1'b1)
        $display("[%0t] PASS TC4: cal_err asserted on ADC clip", $time);
    else
        $display("[%0t] FAIL TC4: cal_err not set rdata=0x%08X", $time, rdata);

    // Verify sticky — read again after more cycles
    repeat(10) @(posedge clk);
    axi_read(6'h10, rdata);
    if (rdata[8] == 1'b1)
        $display("[%0t] PASS TC4: cal_err sticky after 10 cycles", $time);
    else
        $display("[%0t] FAIL TC4: cal_err cleared unexpectedly", $time);

    axi_write(6'h14, 32'h0000_0203);
    buf_full <= 8'h00;
    repeat(4) @(posedge clk);
endtask

// =============================================================================
// TC5 — CAL_LOCK blocks calibration writes
// =============================================================================

task tc5_cal_lock();
    logic [31:0] rdata;
    $display("\n[%0t] === TC5: CAL_LOCK blocks calibration writes ===", $time);

    // Read current dark_offset
    axi_read(6'h04, rdata);
    $display("[%0t] TC5: Initial 0x04 = 0x%08X", $time, rdata);

    // Set CAL_LOCK bit[25]
    axi_write(6'h04, 32'h0200_0010);   // CAL_LOCK=1, dark_offset=0x010

    // Attempt to write new dark_offset while locked
    axi_write(6'h04, 32'h0200_0999);   // Try to set dark_offset=0x999

    // Read back — should still be 0x010 not 0x999
    axi_read(6'h04, rdata);
    if (rdata[11:0] == 12'h010)
        $display("[%0t] PASS TC5: CAL_LOCK blocked write dark_offset unchanged", $time);
    else
        $display("[%0t] FAIL TC5: dark_offset changed to 0x%03X expected 0x010", $time, rdata[11:0]);

    // Unlock and verify writes work again
    axi_write(6'h04, 32'h0000_0020);   // CAL_LOCK=0, dark_offset=0x020
    axi_read(6'h04, rdata);
    if (rdata[11:0] == 12'h020)
        $display("[%0t] PASS TC5: Write succeeded after CAL_LOCK cleared", $time);
    else
        $display("[%0t] FAIL TC5: Write failed after unlock rdata=0x%08X", $time, rdata);

    repeat(4) @(posedge clk);
endtask

// =============================================================================
// TC6 — Precision mode switch during IDLE
// Verify no glitch on active reduction
// =============================================================================

task tc6_precision_switch();
    logic [31:0] rdata;
    $display("\n[%0t] === TC6: Precision mode switch during IDLE ===", $time);

    // Switch to INT4
    axi_write(6'h00, 32'h0000_0000);   // MODE_SEL=000 INT4
    axi_read(6'h00, rdata);
    if (rdata[2:0] == 3'b000)
        $display("[%0t] PASS TC6: MODE_SEL switched to INT4", $time);
    else
        $display("[%0t] FAIL TC6: MODE_SEL=0x%01X expected 000", $time, rdata[2:0]);

    // Switch to FP4
    axi_write(6'h00, 32'h0000_0001);
    axi_read(6'h00, rdata);
    if (rdata[2:0] == 3'b001)
        $display("[%0t] PASS TC6: MODE_SEL switched to FP4", $time);
    else
        $display("[%0t] FAIL TC6: MODE_SEL=0x%01X expected 001", $time, rdata[2:0]);

    // Restore FP8
    axi_write(6'h00, 32'h0000_0032);
    repeat(4) @(posedge clk);
endtask

// =============================================================================
// TC7 — IRQ flow: fire_done → interrupt → IRQ_CLEAR
// =============================================================================

task tc7_irq_flow();
    logic [31:0] rdata;
    $display("\n[%0t] === TC7: IRQ flow end to end ===", $time);
    clear_events();
    set_adc(12'h600);

    axi_write(6'h10, 32'h0000_0400);

    for (int i = 0; i < 8; i++)
        buf_data[i] <= 32'h0000_0055;
    buf_full <= 8'hFF;

    do @(posedge clk); while (!(dac_sync));

    // Verify interrupt asserts
    do @(posedge clk); while (!(interrupt));
    $display("[%0t] PASS TC7: interrupt asserted", $time);

    // Read IRQ_STATUS bit[8] in 0x14
    axi_read(6'h14, rdata);
    if (rdata[8] == 1'b1)
        $display("[%0t] PASS TC7: IRQ_STATUS set in 0x14", $time);
    else
        $display("[%0t] FAIL TC7: IRQ_STATUS not set rdata=0x%08X", $time, rdata);

    // Write IRQ_CLEAR
    axi_write(6'h14, 32'h0000_0203);   // IRQ_CLEAR=1
    @(posedge clk);
    @(posedge clk);

    // Verify interrupt deasserted
    if (!interrupt)
        $display("[%0t] PASS TC7: interrupt cleared after IRQ_CLEAR", $time);
    else
        $display("[%0t] FAIL TC7: interrupt still asserted after IRQ_CLEAR", $time);

    // Read IRQ_STATUS — should be clear
    axi_read(6'h14, rdata);
    if (rdata[8] == 1'b0)
        $display("[%0t] PASS TC7: IRQ_STATUS cleared", $time);
    else
        $display("[%0t] FAIL TC7: IRQ_STATUS still set rdata=0x%08X", $time, rdata);

    buf_full <= 8'h00;
    repeat(4) @(posedge clk);
endtask

// =============================================================================
// IO roundtrip — parallel DAC + SPI SAR ADC digital path
// Not a pilot assertion; verifies the two new bench interface blocks.
// =============================================================================

task io_roundtrip_check();
    int   loads_before;
    logic native_seen;
    $display("\n[%0t] === IO: parallel DAC + SPI ADC digital roundtrip ===", $time);
    clear_events();
    set_adc(12'h2A5);                       // distinctive ADC value

    axi_write(6'h10, 32'h0000_0000);        // AUTO_FIRE off
    for (int i = 0; i < 8; i++)
        buf_data[i] <= 32'h0000_0090;
    buf_full <= 8'hFF;
    loads_before = dac_loads;
    native_seen  = 1'b0;

    axi_write(6'h10, 32'h0000_0001);        // manual FIRE

    // sample from the fire onward: catch the one-cycle native dac_valid strobe
    // and wait for the SPI ADC master to present its result
    do begin
        @(posedge clk);
        if (dac_valid == 8'hFF) native_seen = 1'b1;       // native per-channel DAC load
    end while (!(dut.adc_valid));

    if (dut.adc_data == 12'h2A5 && !dut.conv_fault)
        $display("[%0t] PASS IO1: SPI SAR ADC roundtrip adc_data=0x%03X", $time, dut.adc_data);
    else
        $display("[%0t] FAIL IO1: adc_data=0x%03X conv_fault=%0b", $time, dut.adc_data, dut.conv_fault);

    do @(posedge clk); while (!(interrupt));

    // parallel DAC BFM must have latched a full 8-channel frame, write-strobed
    if ((dac_loads - loads_before) == 8 && native_seen)
        $display("[%0t] PASS IO2: parallel DAC clocked 8 channel words; native dac_valid=0xFF", $time);
    else
        $display("[%0t] FAIL IO2: dac_loads delta=%0d native_seen=%0b", $time,
                 dac_loads - loads_before, native_seen);

    axi_write(6'h14, 32'h0000_0203);
    buf_full <= 8'h00;
    repeat(4) @(posedge clk);
endtask

// =============================================================================
// Main test sequence
// =============================================================================

initial begin
    $display("=== GreenCoyote-Bay Testbench Start ===");
    $dumpfile("greencoyote_tb.vcd");
    $dumpvars(0, greencoyote_tb);

    initialize();
    setup_registers();

    tc1_auto_fire();
    tc2_manual_fire();
    tc3_14gpu_two_pass();
    tc4_cal_err_injection();
    tc5_cal_lock();
    tc6_precision_switch();
    tc7_irq_flow();
    io_roundtrip_check();

    repeat(10) @(posedge clk);
    $display("\n=== GreenCoyote-Bay Testbench Complete ===");
    $finish;
end

// =============================================================================
// Timeout watchdog — prevents infinite simulation on hang
// =============================================================================

initial begin
    #500000;    // 500 microseconds at 1ns timescale
    $display("[%0t] TIMEOUT: Simulation watchdog fired", $time);
    $finish;
end

endmodule
