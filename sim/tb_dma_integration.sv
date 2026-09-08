// =============================================================================
// GreenCoyote-Bay — Streaming Tensor DMA : directed integration testbench
// =============================================================================
// Exercises greencoyote_top end to end for the inbound operand path:
//   MMIO descriptor write (DMA_DESC_WINDOW auto-increment)  -> ring
//   MMIO doorbell (DMA_DESC_TAIL)                            -> walker starts
//   mock AXI4-Slave memory (deterministic counter data)     -> line buffers
//   dma_armed rises (weight tile loaded + WINDOW_W act rows) -> sequencer runs
//   sequencer seq_fire consumes one operand row per opt_clk  -> checked in order
//
// Deterministic memory model: read beat `b` of a burst based at word address
// `Aw` returns  {16{ 32'(Aw + b) }}  on the 512-bit R data bus. The DMA packs
// bytes little-endian into the line buffers, so the first activation operand
// row (128 bits) read back is {4{ 32'(act_base_word) }}, incrementing once per
// 512-bit beat as the sequencer walks the buffer.
//
// PASS criterion:
//   * dma_armed asserts,
//   * >= 64 seq_fire pulses observed, all while dma_armed high,
//   * every dma_operand_valid activation row matches the expected counter.
// Prints  === tb_dma_integration: ALL CHECKS PASS ===  on success.
// =============================================================================
`timescale 1ns/1ps

module tb_dma_integration;

    import greencoyote_regmap_pkg::*;

    // ---- clocks / reset ----
    logic user_clk = 1'b0;
    logic opt_clk  = 1'b0;
    logic rst_n    = 1'b0;
    logic opt_rst_n= 1'b0;

    always #4.0 user_clk = ~user_clk;   // 125 MHz (period 8 ns) — stands in for 300 MHz
    always #0.5 opt_clk  = ~opt_clk;    // 1.0 GHz (period 1 ns) — stands in for 2.0 GHz T_fire

    // ---- AXI-Lite (host MMIO) ----
    logic [7:0]  s_awaddr;  logic s_awvalid; logic s_awready;
    logic [31:0] s_wdata;   logic [3:0] s_wstrb = 4'hF; logic s_wvalid; logic s_wready;
    logic [1:0]  s_bresp;   logic s_bvalid;  logic s_bready = 1'b1;
    logic [7:0]  s_araddr;  logic s_arvalid; logic s_arready;
    logic [31:0] s_rdata;   logic [1:0] s_rresp; logic s_rvalid; logic s_rready = 1'b1;

    // ---- DMA AXI4 read master : ACT + WT ports ----
    logic [3:0]   a_arid;  logic [47:0] a_araddr; logic [7:0] a_arlen; logic [2:0] a_arsize;
    logic [1:0]   a_arburst; logic [3:0] a_arcache; logic [2:0] a_arprot; logic a_arvalid;
    logic         a_arready; logic [3:0] a_rid; logic [511:0] a_rdata; logic [1:0] a_rresp;
    logic         a_rlast; logic a_rvalid; logic a_rready;

    logic [3:0]   w_arid;  logic [47:0] w_araddr; logic [7:0] w_arlen; logic [2:0] w_arsize;
    logic [1:0]   w_arburst; logic [3:0] w_arcache; logic [2:0] w_arprot; logic w_arvalid;
    logic         w_arready; logic [3:0] w_rid; logic [511:0] w_rdata; logic [1:0] w_rresp;
    logic         w_rlast; logic w_rvalid; logic w_rready;

    // ---- observation taps ----
    logic dma_armed_o, dma_underrun_o, dma_operand_valid_o;

    // tied-off legacy buffer path
    logic [31:0] tb_buf_data [0:7];
    initial for (int i = 0; i < 8; i++) tb_buf_data[i] = 32'h0;

    // =====================================================================
    // DUT
    // =====================================================================
    greencoyote_top #(.CS_FIFO_PATH(1'b0)) dut (
        .user_clk (user_clk), .peripheral_aresetn (rst_n), .core_clk (user_clk),

        .s_axi_awaddr(s_awaddr), .s_axi_awvalid(s_awvalid), .s_axi_awready(s_awready),
        .s_axi_wdata(s_wdata), .s_axi_wstrb(s_wstrb), .s_axi_wvalid(s_wvalid), .s_axi_wready(s_wready),
        .s_axi_bresp(s_bresp), .s_axi_bvalid(s_bvalid), .s_axi_bready(s_bready),
        .s_axi_araddr(s_araddr), .s_axi_arvalid(s_arvalid), .s_axi_arready(s_arready),
        .s_axi_rdata(s_rdata), .s_axi_rresp(s_rresp), .s_axi_rvalid(s_rvalid), .s_axi_rready(s_rready),

        .buf_data (tb_buf_data), .buf_full (8'h00), .buf_clear (),

        .m_axis_cs_tvalid(1'b0), .m_axis_cs_tready(), .m_axis_cs_tdata(32'h0),
        .m_axis_cs_tlast(1'b0), .m_axis_cs_tid(4'h0), .m_axis_cs_tuser(6'h0), .m_axis_cs_tkeep(4'h0),

        .dac_data(), .dac_valid(), .dac_sync(),
        .stage_result(), .stage_result_valid(),
        .m_axis_res_tvalid(), .m_axis_res_tready(1'b1), .m_axis_res_tdata(),
        .m_axis_res_tlast(), .m_axis_res_tid(), .m_axis_res_tuser(), .m_axis_res_tkeep(),
        .dac_p_data(), .dac_p_chan(), .dac_p_clk(), .dac_p_wr_n(),
        .adc_sclk(), .adc_cs_n(), .adc_mosi(), .adc_miso(1'b0),
        .interrupt(),
        .xbar_port_dest(), .xbar_mode(), .xbar_update(),
        .train_mode(), .dac_freeze(), .sidecar_enable(), .lora_rank(), .alpha_scaled(),
        .lora_tile_row(), .lora_tile_col(),
        .cell_count(), .grad_reduce_en(), .grad_reduce_fire(), .auto_grad_reduce(),
        .grad_scale(), .n_spi_buses(), .spi_clk_div(),
        .exec_start(), .exec_stop(), .exec_reset(), .exec_step(),
        .bram_wr_addr(), .bram_wr_data_lo(), .bram_wr_data_hi(), .bram_wr_en(), .lc_init(),
        .rollback_en(), .rollback_limit(), .fault_irq_en(),
        .active_tid(), .target_tid(), .shutdown_init(), .emergency_shutdown_sw(),
        .flush_ombs(), .irq_before_power(), .shutdown_timeout_ms(), .tile_select(),

        // ---- streaming DMA ----
        .opt_clk (opt_clk), .opt_rst_n (opt_rst_n),
        .dma_act_arid(a_arid), .dma_act_araddr(a_araddr), .dma_act_arlen(a_arlen),
        .dma_act_arsize(a_arsize), .dma_act_arburst(a_arburst), .dma_act_arcache(a_arcache),
        .dma_act_arprot(a_arprot), .dma_act_arvalid(a_arvalid), .dma_act_arready(a_arready),
        .dma_act_rid(a_rid), .dma_act_rdata(a_rdata), .dma_act_rresp(a_rresp),
        .dma_act_rlast(a_rlast), .dma_act_rvalid(a_rvalid), .dma_act_rready(a_rready),
        .dma_wt_arid(w_arid), .dma_wt_araddr(w_araddr), .dma_wt_arlen(w_arlen),
        .dma_wt_arsize(w_arsize), .dma_wt_arburst(w_arburst), .dma_wt_arcache(w_arcache),
        .dma_wt_arprot(w_arprot), .dma_wt_arvalid(w_arvalid), .dma_wt_arready(w_arready),
        .dma_wt_rid(w_rid), .dma_wt_rdata(w_rdata), .dma_wt_rresp(w_rresp),
        .dma_wt_rlast(w_rlast), .dma_wt_rvalid(w_rvalid), .dma_wt_rready(w_rready),
        .dma_armed_o(dma_armed_o), .dma_underrun_o(dma_underrun_o),
        .dma_operand_valid_o(dma_operand_valid_o)
    );

    // =====================================================================
    // Mock AXI4 read slave — deterministic counter memory, one block per port.
    // AR accepted combinationally when idle; R data is a combinational function
    // of (captured base word address, beat index).
    //   word[Aw + beat*16 + lw] = Aw + beat*16 + lw     (32-bit, wraps)
    // =====================================================================

    function automatic logic [511:0] mem_beat(input [29:0] base_word, input [8:0] beat);
        logic [511:0] v;
        for (int lw = 0; lw < 16; lw++)
            v[lw*32 +: 32] = {2'b00, base_word} + (beat*16) + lw[31:0];
        return v;
    endfunction

    // ---- ACT port slave ----
    logic        a_busy;
    logic [29:0] a_base_w;
    logic [8:0]  a_beat, a_nbeat;
    assign a_arready = !a_busy;
    assign a_rvalid  =  a_busy;
    assign a_rlast   =  a_busy && (a_beat == a_nbeat - 9'd1);
    assign a_rdata   = mem_beat(a_base_w, a_beat);
    assign a_rid     = 4'h0;
    assign a_rresp   = 2'b00;
    always_ff @(posedge user_clk or negedge rst_n) begin
        if (!rst_n) begin
            a_busy <= 1'b0; a_base_w <= '0; a_beat <= 9'd0; a_nbeat <= 9'd0;
        end else if (!a_busy) begin
            if (a_arvalid) begin
                a_busy   <= 1'b1;
                a_base_w <= a_araddr[31:2];
                a_nbeat  <= {1'b0, a_arlen} + 9'd1;
                a_beat   <= 9'd0;
            end
        end else if (a_rready) begin
            if (a_beat == a_nbeat - 9'd1) a_busy <= 1'b0;
            else                          a_beat <= a_beat + 9'd1;
        end
    end

    // ---- WT port slave ----
    logic        w_busy;
    logic [29:0] w_base_w;
    logic [8:0]  w_beat, w_nbeat;
    assign w_arready = !w_busy;
    assign w_rvalid  =  w_busy;
    assign w_rlast   =  w_busy && (w_beat == w_nbeat - 9'd1);
    assign w_rdata   = mem_beat(w_base_w, w_beat);
    assign w_rid     = 4'h1;
    assign w_rresp   = 2'b00;
    always_ff @(posedge user_clk or negedge rst_n) begin
        if (!rst_n) begin
            w_busy <= 1'b0; w_base_w <= '0; w_beat <= 9'd0; w_nbeat <= 9'd0;
        end else if (!w_busy) begin
            if (w_arvalid) begin
                w_busy   <= 1'b1;
                w_base_w <= w_araddr[31:2];
                w_nbeat  <= {1'b0, w_arlen} + 9'd1;
                w_beat   <= 9'd0;
            end
        end else if (w_rready) begin
            if (w_beat == w_nbeat - 9'd1) w_busy <= 1'b0;
            else                          w_beat <= w_beat + 9'd1;
        end
    end

    // ---- lightweight progress trace ----
    int trace_i = 0;
    always_ff @(posedge user_clk) begin
        trace_i <= trace_i + 1;
        if (trace_i % 4000 == 0)
            $display("[t=%0d] walker.st=%0d wt_loaded=%0b rows_buffered=%0d armed=%b fires=%0d",
                     trace_i, dut.u_streaming_dma.u_walker.st,
                     dut.u_streaming_dma.wt_loaded_opt,
                     dut.u_streaming_dma.rows_buffered_opt, dma_armed_o, fire_seen);
    end

    // =====================================================================
    // Host MMIO write task (AXI-Lite)
    // =====================================================================
    // Sequential AXI-Lite write. greencoyote_axi_lite_wrapper is deterministic:
    // WR_IDLE (awready=1) -> WR_DATA (wready=1) -> WR_RESP (bvalid=1) -> WR_IDLE.
    // Drive with non-blocking so each value is stable for the next posedge.
    task automatic mmio_write(input [7:0] addr, input [31:0] data);
        @(posedge user_clk);
        s_awaddr <= addr; s_awvalid <= 1'b1;
        @(posedge user_clk);                       // AW captured
        s_awvalid <= 1'b0; s_wvalid <= 1'b1; s_wdata <= data;
        @(posedge user_clk);                       // W captured -> reg_write_en
        s_wvalid <= 1'b0;
        @(posedge user_clk);                       // WR_RESP -> bvalid, bready=1
        @(posedge user_clk);                       // back to WR_IDLE
    endtask

    // build one 256-bit tensor descriptor (streaming_dma_architecture.md sec 2.2)
    function automatic logic [255:0] make_desc(
        input [47:0] base, input [3:0] elog2,
        input [15:0] inner_ext, input [31:0] inner_str,
        input [15:0] outer_ext, input [31:0] outer_str,
        input [11:0] batch_ext, input [31:0] batch_str,
        input [15:0] flags);
        logic [255:0] d;
        d = '0;
        d[47:0]     = base;
        d[51:48]    = elog2;
        d[67:52]    = inner_ext;
        d[99:68]    = inner_str;
        d[115:100]  = outer_ext;
        d[147:116]  = outer_str;
        d[175:164]  = batch_ext;
        d[207:176]  = batch_str;
        d[223:208]  = flags;
        return d;
    endfunction

    task automatic push_desc(input logic [255:0] d);
        for (int wi = 0; wi < 8; wi++)
            mmio_write(ADDR_DMA_DESC_WINDOW[7:0], d[wi*32 +: 32]);
    endtask

    // =====================================================================
    // Checker : activation operands out of the sequencer, in order
    // =====================================================================
    localparam logic [31:0] ACT_BASE_WORD = 32'h0002_0000 >> 2;   // 0x8000
    int  fire_seen = 0;
    int  opv_seen  = 0;
    int  errors    = 0;
    logic saw_armed = 1'b0;
    logic [127:0] exp128;

    // sample the sequencer's DMA beat interface via hierarchical refs
    wire         tb_seq_fire = dut.seq_fire;
    wire         tb_armed    = dut.dma_armed;
    wire         tb_opv      = dut.dma_operand_valid;
    wire [127:0] tb_act_ops  = dut.dma_act_operands;

    always @(posedge opt_clk) begin
        if (opt_rst_n) begin
            if (tb_armed) saw_armed = 1'b1;
            if (tb_seq_fire) begin
                fire_seen = fire_seen + 1;
                if (!tb_armed) begin
                    $display("[%0t] FAIL seq_fire while dma_armed low", $time);
                    errors = errors + 1;
                end
            end
            if (tb_opv) begin
                // deterministic memory: 512-bit beat b holds words
                //   base_word + b*16 + [0..15]; a 128-bit operand row = 4 words.
                exp128 = { 32'(ACT_BASE_WORD + opv_seen*4 + 3),
                           32'(ACT_BASE_WORD + opv_seen*4 + 2),
                           32'(ACT_BASE_WORD + opv_seen*4 + 1),
                           32'(ACT_BASE_WORD + opv_seen*4 + 0) };
                if (tb_act_ops !== exp128 && errors < 12) begin
                    $display("[%0t] FAIL operand row %0d: got %h expected %h",
                             $time, opv_seen, tb_act_ops, exp128);
                    errors = errors + 1;
                end
                opv_seen = opv_seen + 1;
            end
        end
    end

    // =====================================================================
    // Stimulus
    // =====================================================================
    logic [255:0] desc_wt, desc_act;

    initial begin
        s_awvalid = 0; s_wvalid = 0; s_arvalid = 0; s_awaddr = 0; s_wdata = 0; s_araddr = 0;
        rst_n = 0; opt_rst_n = 0;
        repeat (8) @(posedge user_clk);
        rst_n = 1; opt_rst_n = 1;
        repeat (4) @(posedge user_clk);
        $display("[%0t] STIM start  s_awready=%b s_wready=%b", $time, s_awready, s_wready);

        // PRECISION_MODE.MODE_SEL resets to FP8 (3'd2); descriptors carry PRECISION = 2.
        // -- weight tile descriptor: 64 rows x 8192 B, base 0x1_0000, LAST=0, WEIGHT=1
        desc_wt  = make_desc(48'h0001_0000, 4'd1, 16'd8192, 32'd1,
                             16'd64, 32'd8192, 12'd1, 32'd0,
                             16'h0024);   // flags: PRECISION=2<<4 | WEIGHT(bit2)
        // -- activation descriptor: 1 row x 16384 B (a full 16 KiB ping-pong bank),
        //    base 0x2_0000, LAST=1
        desc_act = make_desc(48'h0002_0000, 4'd1, 16'd16384, 32'd1,
                             16'd1, 32'd0, 12'd1, 32'd0,
                             16'h0021);   // flags: PRECISION=2<<4 | LAST(bit0)

        // program the DMA
        mmio_write(ADDR_DMA_WEIGHT_TILE_LO, 32'h0001_0000); $display("[%0t] wrote WT_LO", $time);
        mmio_write(ADDR_DMA_WEIGHT_TILE_HI, 32'h0000_0000); $display("[%0t] wrote WT_HI", $time);
        mmio_write(ADDR_DMA_CTRL,
                   (32'd1 << DMA_CTRL_EN_LSB) | (32'd8 << DMA_CTRL_WINDOW_W_LSB));
        $display("[%0t] wrote DMA_CTRL en=%b", $time, dut.u_streaming_dma.r_en);
        push_desc(desc_wt);
        push_desc(desc_act);
        $display("[%0t] pushed descs wr_idx=%0d", $time, dut.u_streaming_dma.ring_wr_idx);
        mmio_write(ADDR_DMA_DESC_TAIL, 32'd2);
        $display("[%0t] doorbell tail=%0d", $time, dut.u_streaming_dma.ring_tail_q);

        // wait for the feed to arm (weight tile loaded + 1 full activation bank)
        fork
            begin : arm_wait
                int guard; guard = 0;
                while (!dma_armed_o && guard < 200000) begin @(posedge user_clk); guard++; end
                if (!dma_armed_o) begin
                    $display("FAIL: dma_armed never asserted (guard=%0d)", guard);
                    errors = errors + 1;
                end else begin
                    $display("[%0t] dma_armed asserted after %0d user_clk", $time, guard);
                end
            end
        join

        // let the sequencer consume a stretch of operand rows
        repeat (4000) @(posedge opt_clk);

        // -------- verdict --------
        // dma_armed correctly de-asserts once the single programmed activation
        // bank (1024 rows) is drained and there is no refill -> check that it
        // *rose*, that every consumed row matched, and that nothing under-ran.
        $display("saw_armed=%0b fire_seen=%0d opv_seen=%0d underrun=%0b errors=%0d",
                 saw_armed, fire_seen, opv_seen, dma_underrun_o, errors);
        if (errors == 0 && saw_armed && fire_seen >= 512 && opv_seen >= 512 && !dma_underrun_o)
            $display("=== tb_dma_integration: ALL CHECKS PASS ===");
        else
            $display("=== tb_dma_integration: FAIL ===");
        $finish;
    end

    // global watchdog (cycle-based, timescale-independent)
    initial begin
        repeat (400_000) @(posedge user_clk);
        $display("=== tb_dma_integration: TIMEOUT ===");
        $finish;
    end

endmodule
