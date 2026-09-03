// =============================================================================
// GreenCoyote-Bay — M_AXIS_CS FIFO-path testbench
// =============================================================================
// Exercises greencoyote_top with CS_FIFO_PATH = 1: a reduction is driven end to
// end by M_AXIS_CS beats through the per-lane dual-clock FIFOs, with core_clk
// (write domain) asynchronous to and faster than user_clk (read domain).
//
// Checks:
//   C1 — 8 beats (one per cell_lane) fill the 8 lane FIFOs; seq_buf_full == 0xFF
//   C2 — AUTO_FIRE then completes: dac_sync, fire_done/interrupt
//   C3 — FIFO pop: cs_buf_clear pulses 0xFF, lane FIFOs drain (cs_buf_full == 0)
//   C4 — external buf_clear stays 0 on the FIFO path
//   C5 — write backpressure: filling one lane past depth drops m_axis_cs_tready
// =============================================================================

`timescale 1ns/1ps

module tb_cs_fifo_path;

logic user_clk = 0;
logic core_clk = 0;
logic rst_n;

always #5   user_clk = ~user_clk;   // 100 MHz  (read domain)
always #3.2 core_clk = ~core_clk;   // ~156 MHz (write domain, async)

// ---- DUT I/O ----
logic [7:0]  s_axi_awaddr;  logic s_axi_awvalid, s_axi_awready;
logic [31:0] s_axi_wdata;   logic [3:0] s_axi_wstrb;
logic        s_axi_wvalid,  s_axi_wready;
logic [1:0]  s_axi_bresp;   logic s_axi_bvalid, s_axi_bready;
logic [7:0]  s_axi_araddr;  logic s_axi_arvalid, s_axi_arready;
logic [31:0] s_axi_rdata;   logic [1:0] s_axi_rresp;
logic        s_axi_rvalid,  s_axi_rready;

logic [31:0] buf_data [0:7];
logic [7:0]  buf_full;
logic [7:0]  buf_clear;

logic [11:0] dac_data [0:7];
logic [7:0]  dac_valid;
logic        dac_sync;

logic [13:0] dac_p_data;  logic [2:0] dac_p_chan;
logic        dac_p_clk,   dac_p_wr_n;
logic        adc_sclk, adc_cs_n, adc_mosi, adc_miso;
logic        interrupt;

logic        cs_tvalid, cs_tready, cs_tlast;
logic [31:0] cs_tdata;
logic [3:0]  cs_tid;
logic [5:0]  cs_tuser;

greencoyote_top #(
    .CS_FIFO_PATH (1'b1),
    .CS_FIFO_AW   (2)          // depth 4
) dut (
    .user_clk           (user_clk),
    .peripheral_aresetn (rst_n),
    .core_clk           (core_clk),

    .m_axis_cs_tvalid   (cs_tvalid),
    .m_axis_cs_tready   (cs_tready),
    .m_axis_cs_tdata    (cs_tdata),
    .m_axis_cs_tlast    (cs_tlast),
    .m_axis_cs_tid      (cs_tid),
    .m_axis_cs_tuser    (cs_tuser),
    .m_axis_cs_tkeep    (4'hF),

    .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
    .s_axi_wdata(s_axi_wdata),   .s_axi_wstrb(s_axi_wstrb),
    .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
    .s_axi_bresp(s_axi_bresp),   .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
    .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
    .s_axi_rdata(s_axi_rdata),   .s_axi_rresp(s_axi_rresp),
    .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),

    .buf_data(buf_data), .buf_full(buf_full), .buf_clear(buf_clear),
    .dac_data(dac_data), .dac_valid(dac_valid), .dac_sync(dac_sync),
    .dac_p_data(dac_p_data), .dac_p_chan(dac_p_chan),
    .dac_p_clk(dac_p_clk),   .dac_p_wr_n(dac_p_wr_n),
    .adc_sclk(adc_sclk), .adc_cs_n(adc_cs_n), .adc_mosi(adc_mosi), .adc_miso(adc_miso),
    .interrupt(interrupt)
);

// ---- SPI SAR ADC BFM (mid-scale) ----
logic [11:0] adc_result = 12'h800;
logic [15:0] miso_shift;
initial adc_miso = 1'b0;
always @(negedge adc_cs_n) begin miso_shift = {4'h0, adc_result}; adc_miso = miso_shift[15]; end
always @(negedge adc_sclk) if (!adc_cs_n) begin miso_shift = {miso_shift[14:0],1'b0}; adc_miso = miso_shift[15]; end
always @(posedge adc_cs_n) adc_miso = 1'b0;

// ---- debug probe ----
initial if ($test$plusargs("dbg"))
    forever begin
        @(posedge user_clk);
        $display("[%0t] st=%0d cs_full=%02x seq_full=%02x qfull=%b qfp=%b afire=%b fpulse=%b m_act=%b dac_sync=%b",
                 $time, dut.u_sequencer.state, dut.cs_buf_full, dut.seq_buf_full,
                 dut.queue_full, dut.u_pilot_regs.queue_full_prev, dut.u_pilot_regs.r_auto_fire,
                 dut.u_pilot_regs.r_fire_pulse, dut.mode_active, dac_sync);
    end

int errors = 0;
task check(input bit ok, input string msg);
    if (ok) $display("[%0t] PASS: %s", $time, msg);
    else  begin $display("[%0t] FAIL: %s", $time, msg); errors++; end
endtask

// latch transient strobes for after-the-fact checks
logic saw_dac_sync;
logic [7:0] saw_cs_clear;
always @(posedge user_clk) begin
    if (dac_sync)        saw_dac_sync <= 1'b1;
    if (|dut.cs_buf_clear) saw_cs_clear <= dut.cs_buf_clear;
end

// wait for `sig` high, up to `lim` user_clk edges; returns 1 on success
function automatic void clear_strobes();
    saw_dac_sync = 1'b0;
    saw_cs_clear = 8'h00;
endfunction

// ---- AXI-Lite write ----
task axi_write(input logic [7:0] addr, input logic [31:0] data);
    @(posedge user_clk);
    s_axi_awaddr <= addr; s_axi_awvalid <= 1'b1;
    s_axi_wdata  <= data; s_axi_wstrb <= 4'hF; s_axi_wvalid <= 1'b1; s_axi_bready <= 1'b1;
    do @(posedge user_clk); while (!s_axi_awready);
    s_axi_awvalid <= 1'b0;
    do @(posedge user_clk); while (!s_axi_wready);
    s_axi_wvalid <= 1'b0;
    do @(posedge user_clk); while (!s_axi_bvalid);
    @(posedge user_clk); s_axi_bready <= 1'b0;
endtask

// ---- one M_AXIS_CS beat, on the core_clk (write) domain ----
task cs_beat(input logic [3:0] lane, input logic [31:0] data, input logic last);
    @(posedge core_clk);
    cs_tvalid <= 1'b1; cs_tdata <= data; cs_tuser <= {2'b00, lane}; cs_tlast <= last; cs_tid <= 4'h5;
    do @(posedge core_clk); while (!cs_tready);
    cs_tvalid <= 1'b0; cs_tlast <= 1'b0;
endtask

initial begin
    $dumpfile("tb_cs_fifo_path.vcd");
    $dumpvars(0, tb_cs_fifo_path);

    rst_n = 1'b0;
    s_axi_awvalid=0; s_axi_wvalid=0; s_axi_bready=0; s_axi_arvalid=0; s_axi_rready=0;
    s_axi_awaddr=0; s_axi_wdata=0; s_axi_wstrb=4'hF; s_axi_araddr=0;
    cs_tvalid=0; cs_tdata=0; cs_tuser=0; cs_tlast=0; cs_tid=0;
    for (int i=0;i<8;i++) buf_data[i]=32'h0;
    buf_full = 8'h00;
    repeat (8) @(posedge user_clk);
    rst_n = 1'b1;
    repeat (8) @(posedge user_clk);

    // FP8, unity trim, small dark offset
    axi_write(8'h00, 32'h0000_0032);
    axi_write(8'h08, 32'hFFFF_FFFF);
    axi_write(8'h0C, 32'hFFFF_FFFF);
    axi_write(8'h04, 32'h0100_0010);
    axi_write(8'h14, 32'h0000_0003);   // IRQ_EN + FIRE_DONE
    axi_write(8'h10, 32'h0000_0400);   // AUTO_FIRE

    clear_strobes();

    // ---- C1: push 8 beats, one per lane; FIFOs fill and cross to user_clk ----
    for (int l=0; l<8; l++)
        cs_beat(l[3:0], 32'h0000_0100 + l, 1'b1);   // distinct Q17.14 payloads

    begin
        int g; g = 0;
        while (dut.seq_buf_full !== 8'hFF && g < 200) begin @(posedge user_clk); g++; end
        check(dut.seq_buf_full === 8'hFF,
              "C1: 8 M_AXIS_CS beats fill 8 lane FIFOs (seq_buf_full==0xFF)");
    end

    // ---- C2: reduction runs to completion, driven purely by the stream ----
    begin
        int g; g = 0;
        while (!interrupt && g < 8000) begin @(posedge user_clk); g++; end
        check(interrupt, "C2: reduction completed (interrupt) driven by M_AXIS_CS");
        check(saw_dac_sync, "C2: dac_sync fired on the FIFO path");
    end

    // ---- C3 / C4: FIFO drained via cs_buf_clear, external buf_clear untouched ----
    repeat (10) @(posedge user_clk);
    check(dut.cs_buf_full === 8'h00, "C3: lane FIFOs drained after reduction (cs_buf_full==0)");
    check(saw_cs_clear === 8'hFF,    "C3: cs_buf_clear pulsed 0xFF (record pop)");
    check(buf_clear === 8'h00,       "C4: external buf_clear stays 0 on the FIFO path");

    // clear IRQ, drop AUTO_FIRE so a re-fill does not immediately fire
    axi_write(8'h14, 32'h0000_0203);
    axi_write(8'h10, 32'h0000_0000);
    repeat (10) @(posedge user_clk);

    // ---- C5: write backpressure on one lane (depth 4) ----
    begin
        int accepted; logic saw_stall;
        accepted = 0; saw_stall = 1'b0;
        for (int n=0; n<8; n++) begin
            @(posedge core_clk);
            cs_tvalid <= 1'b1; cs_tdata <= 32'hDEAD_0000 + n;
            cs_tuser  <= 6'h03; cs_tlast <= 1'b1; cs_tid <= 4'h5;   // hammer lane 3
            @(posedge core_clk);
            #1;
            if (cs_tready) accepted++; else saw_stall = 1'b1;
        end
        cs_tvalid <= 1'b0; cs_tlast <= 1'b0;
        check(saw_stall && accepted <= 4,
              $sformatf("C5: lane FIFO backpressure (accepted=%0d, tready dropped)", accepted));
    end

    repeat (20) @(posedge user_clk);
    if (errors == 0) $display("\n=== tb_cs_fifo_path: ALL CHECKS PASS ===");
    else             $display("\n=== tb_cs_fifo_path: %0d FAILURE(S) ===", errors);
    $finish;
end

initial begin
    #400000;
    $display("[%0t] TIMEOUT: watchdog", $time);
    $finish;
end

endmodule
