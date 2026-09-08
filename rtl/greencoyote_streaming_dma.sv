// =============================================================================
// GreenCoyote-Bay — Streaming Tensor DMA : top-level wrapper
// Project: ODIN_Bridge / Cascaded Optical Reduction Fabric
// Author:  John A. Green
// Date:    2026-09
// =============================================================================
// Inbound operand feed. Ties together:
//   greencoyote_dma_walker      — 32-byte descriptor walker FSM  (Task 1)
//   greencoyote_dma_axi_master  — 2 x 512-bit AXI4 read + CDC line buffers (Task 2)
//   the DMA_* MMIO block (registers.yaml 0xC4-0xE4, map_version 0.6.0)
//   credit handshake to greencoyote_photonic_sequencer.sv        (Task 3)
//
// LOCKED geometry / sizing: gcb-spec/docs/optical_geometry_spec.md v1.0.0,
// "RTL Hand-off Block". Architecture: gcb-spec/docs/streaming_dma_architecture.md.
//
// Clock domains:
//   user_clk  300 MHz  AXI read master, descriptor walker, MMIO, sequencer hand-off
//   opt_clk   2.0 GHz  operand read ports to the modulator interface (= T_fire)
// The only CDC is user_clk <-> opt_clk (bank tokens via greencoyote_cs_lane_fifo
// inside the axi master, plus the single-bit / advisory syncs collected here).
//
// Synthesizable SystemVerilog, IEEE 1800-2012. Explicit active-low resets.
// =============================================================================

module greencoyote_streaming_dma
    import greencoyote_regmap_pkg::*;
#(
    // ---- LOCKED — optical_geometry_spec.md v1.0.0, RTL Hand-off Block ----
    parameter int N_OPT_CH         = 64,
    parameter int L_CONTRACT       = 16,
    parameter int T_FIRE_PS        = 500,
    parameter int FIRES_PER_WIN    = 512,
    parameter int K_TOTAL          = 8192,
    parameter int OPERAND_BITS     = 8,
    parameter int AXI_DATA_W       = 512,
    parameter int AXI_ID_W         = 4,
    parameter int AXI_ADDR_W       = 48,
    parameter int AXI_MAX_BURST    = 256,
    parameter int ACT_BUF_BANKS    = 2,
    parameter int ACT_BUF_WR_DEPTH = 256,
    parameter int WT_BUF_WR_DEPTH  = 128,
    parameter int DESC_WORDS       = 8,
    parameter int RING_DEPTH       = 32
)(
    input  logic                     user_clk,
    input  logic                     user_rst_n,
    input  logic                     opt_clk,
    input  logic                     opt_rst_n,

    // ---- MMIO slave (DMA aperture 0xC4-0xE4) ----
    input  logic [greencoyote_regmap_pkg::ADDR_WIDTH-1:0] reg_addr,
    input  logic [31:0]              reg_wdata,
    input  logic                     reg_we,
    input  logic                     reg_re,
    output logic [31:0]              reg_rdata,
    output logic                     reg_hit,

    input  logic [2:0]               op_precision,        // PRECISION_MODE.MODE_SEL mirror
    input  logic                     irq_dma_done_en,
    input  logic                     irq_dma_underrun_en,
    output logic                     irq_dma,

    // ---- AXI4 read : ACTIVATION port ----
    output logic [AXI_ID_W-1:0]      act_arid,
    output logic [AXI_ADDR_W-1:0]    act_araddr,
    output logic [7:0]               act_arlen,
    output logic [2:0]               act_arsize,
    output logic [1:0]               act_arburst,
    output logic [3:0]               act_arcache,
    output logic [2:0]               act_arprot,
    output logic                     act_arvalid,
    input  logic                     act_arready,
    input  logic [AXI_ID_W-1:0]      act_rid,
    input  logic [AXI_DATA_W-1:0]    act_rdata,
    input  logic [1:0]               act_rresp,
    input  logic                     act_rlast,
    input  logic                     act_rvalid,
    output logic                     act_rready,

    // ---- AXI4 read : WEIGHT port ----
    output logic [AXI_ID_W-1:0]      wt_arid,
    output logic [AXI_ADDR_W-1:0]    wt_araddr,
    output logic [7:0]               wt_arlen,
    output logic [2:0]               wt_arsize,
    output logic [1:0]               wt_arburst,
    output logic [3:0]               wt_arcache,
    output logic [2:0]               wt_arprot,
    output logic                     wt_arvalid,
    input  logic                     wt_arready,
    input  logic [AXI_ID_W-1:0]      wt_rid,
    input  logic [AXI_DATA_W-1:0]    wt_rdata,
    input  logic [1:0]               wt_rresp,
    input  logic                     wt_rlast,
    input  logic                     wt_rvalid,
    output logic                     wt_rready,

    // ---- credit handshake to greencoyote_photonic_sequencer (optical domain) ----
    input  logic                     seq_fire,
    output logic                     dma_armed,
    output logic                     dma_underrun,

    // ---- operand outputs to the modulator interface (optical domain) ----
    output logic                     operand_valid,
    output logic [L_CONTRACT*OPERAND_BITS-1:0]           act_operands,
    output logic [N_OPT_CH*L_CONTRACT*OPERAND_BITS-1:0]  wt_operands
);

    // ========================================================== localparams
    localparam int RING_AW = $clog2(RING_DEPTH);

    // ========================================================== declarations
    // -- MMIO register storage (user_clk) --
    logic        r_en, r_ring_src;
    logic [3:0]  r_arcache;
    logic [2:0]  r_arprot;
    logic [11:0] r_window_w;
    logic [31:0] r_ring_base_lo, r_wt_base_lo;
    logic [15:0] r_ring_base_hi, r_wt_base_hi, r_desc_tail;
    logic [4:0]  r_ring_sz_log2;
    logic [3:0]  r_wt_shape;
    logic        pulse_arm, pulse_abort, pulse_doorbell, pulse_wt_reload;

    // -- on-die descriptor ring --
    logic [DESC_WORDS*32-1:0] ring_mem [0:RING_DEPTH-1];
    logic [RING_AW-1:0]       ring_wr_idx, ring_tail_q, ring_rd_idx, ring_head_w;
    logic [2:0]               ring_wr_word;

    // -- decode --
    logic dma_addr_hit;

    // -- walker <-> axi master --
    logic                        brq_valid, brq_ready, brq_first, brq_last, brq_is_weight;
    logic [AXI_ADDR_W-1:0]       brq_addr;
    logic [7:0]                  brq_len;
    logic [$clog2(N_OPT_CH)-1:0] brq_dst_bank;
    logic [15:0]                 brq_dst_word;
    logic                        axi_idle;
    logic                        irq_desc_done;
    logic                        ring_rd_en_unused;

    // -- walker status --
    logic        walker_running, walker_desc_err;
    logic [11:0] walker_last_desc_id;

    // -- axi master status (optical domain) --
    logic [11:0] rows_buffered_opt;
    logic        wt_loaded_opt, underrun_opt;

    // -- optical-domain fire path --
    logic [8:0]  wt_rd_col;
    logic        act_rd_en, wt_rd_en;

    // -- CDC syncs --
    (* ASYNC_REG = "TRUE" *) logic [11:0] window_w_m, window_w_s;
    (* ASYNC_REG = "TRUE" *) logic        r_en_m, r_en_opt;
    (* ASYNC_REG = "TRUE" *) logic        armed_m, armed_s;
    (* ASYNC_REG = "TRUE" *) logic        urun_m,  dma_underrun_sync;
    (* ASYNC_REG = "TRUE" *) logic [11:0] rows_m,  s_rows_buffered;
    (* ASYNC_REG = "TRUE" *) logic        wtld_m,  s_wt_loaded;

    // -- addresses --
    wire [AXI_ADDR_W-1:0] ring_base_full = {r_ring_base_hi, r_ring_base_lo};

    assign dma_addr_hit = (reg_addr >= ADDR_DMA_CTRL) && (reg_addr <= ADDR_DMA_STATUS);
    assign reg_hit      = dma_addr_hit;

    // ============================================== MMIO write (user_clk)
    always_ff @(posedge user_clk or negedge user_rst_n) begin
        if (!user_rst_n) begin
            r_en <= 1'b0; r_ring_src <= 1'b0; r_arcache <= 4'h3; r_arprot <= 3'h2;
            r_window_w <= 12'h0;
            r_ring_base_lo <= 32'h0; r_ring_base_hi <= 16'h0; r_ring_sz_log2 <= 5'd5;
            r_desc_tail <= 16'h0; r_wt_base_lo <= 32'h0; r_wt_base_hi <= 16'h0; r_wt_shape <= 4'h0;
            pulse_arm <= 1'b0; pulse_abort <= 1'b0; pulse_doorbell <= 1'b0; pulse_wt_reload <= 1'b0;
            ring_wr_idx <= '0; ring_wr_word <= 3'd0; ring_tail_q <= '0;
        end else begin
            pulse_arm <= 1'b0; pulse_abort <= 1'b0; pulse_doorbell <= 1'b0; pulse_wt_reload <= 1'b0;
            if (reg_we && dma_addr_hit) begin
                unique case (reg_addr)
                    ADDR_DMA_CTRL: begin
                        r_en        <= reg_wdata[DMA_CTRL_EN_LSB];
                        pulse_arm   <= reg_wdata[DMA_CTRL_ARM_LSB];
                        pulse_abort <= reg_wdata[DMA_CTRL_ABORT_LSB];
                        r_ring_src  <= reg_wdata[DMA_CTRL_RING_SRC_LSB];
                        r_arcache   <= reg_wdata[DMA_CTRL_ARCACHE_MSB : DMA_CTRL_ARCACHE_LSB];
                        r_arprot    <= reg_wdata[DMA_CTRL_ARPROT_MSB  : DMA_CTRL_ARPROT_LSB];
                        r_window_w  <= reg_wdata[DMA_CTRL_WINDOW_W_MSB : DMA_CTRL_WINDOW_W_LSB];
                    end
                    ADDR_DMA_DESC_RING_BASE_LO: r_ring_base_lo <= reg_wdata;
                    ADDR_DMA_DESC_RING_BASE_HI: begin
                        r_ring_base_hi <= reg_wdata[DMA_DESC_RING_BASE_HI_RING_BASE_HI_MSB : DMA_DESC_RING_BASE_HI_RING_BASE_HI_LSB];
                        r_ring_sz_log2 <= reg_wdata[DMA_DESC_RING_BASE_HI_RING_SZ_LOG2_MSB : DMA_DESC_RING_BASE_HI_RING_SZ_LOG2_LSB];
                    end
                    ADDR_DMA_DESC_TAIL: begin
                        r_desc_tail    <= reg_wdata[DMA_DESC_TAIL_TAIL_MSB : DMA_DESC_TAIL_TAIL_LSB];
                        pulse_doorbell <= 1'b1;
                        ring_tail_q    <= reg_wdata[RING_AW-1:0];
                    end
                    ADDR_DMA_DESC_WINDOW: begin
                        ring_mem[ring_wr_idx][ring_wr_word*32 +: 32] <= reg_wdata;
                        if (ring_wr_word == 3'd7) begin
                            ring_wr_word <= 3'd0;
                            ring_wr_idx  <= ring_wr_idx + 1'b1;
                        end else begin
                            ring_wr_word <= ring_wr_word + 1'b1;
                        end
                    end
                    ADDR_DMA_WEIGHT_TILE_LO: r_wt_base_lo <= reg_wdata;
                    ADDR_DMA_WEIGHT_TILE_HI: begin
                        r_wt_base_hi    <= reg_wdata[DMA_WEIGHT_TILE_HI_WT_BASE_HI_MSB : DMA_WEIGHT_TILE_HI_WT_BASE_HI_LSB];
                        r_wt_shape      <= reg_wdata[DMA_WEIGHT_TILE_HI_WT_SHAPE_MSB   : DMA_WEIGHT_TILE_HI_WT_SHAPE_LSB];
                        pulse_wt_reload <= 1'b1;
                    end
                    default: ;
                endcase
            end
        end
    end

    // ============================================== MMIO readback
    always_comb begin
        reg_rdata = 32'h0;
        unique case (reg_addr)
            ADDR_DMA_CTRL: begin
                reg_rdata[DMA_CTRL_EN_LSB]       = r_en;
                reg_rdata[DMA_CTRL_RING_SRC_LSB] = r_ring_src;
                reg_rdata[DMA_CTRL_ARCACHE_MSB  : DMA_CTRL_ARCACHE_LSB]  = r_arcache;
                reg_rdata[DMA_CTRL_ARPROT_MSB   : DMA_CTRL_ARPROT_LSB]   = r_arprot;
                reg_rdata[DMA_CTRL_WINDOW_W_MSB : DMA_CTRL_WINDOW_W_LSB] = r_window_w;
            end
            ADDR_DMA_DESC_RING_BASE_LO: reg_rdata = r_ring_base_lo;
            ADDR_DMA_DESC_RING_BASE_HI: begin
                reg_rdata[DMA_DESC_RING_BASE_HI_RING_BASE_HI_MSB : DMA_DESC_RING_BASE_HI_RING_BASE_HI_LSB] = r_ring_base_hi;
                reg_rdata[DMA_DESC_RING_BASE_HI_RING_SZ_LOG2_MSB : DMA_DESC_RING_BASE_HI_RING_SZ_LOG2_LSB] = r_ring_sz_log2;
            end
            ADDR_DMA_DESC_HEAD: reg_rdata[DMA_DESC_HEAD_HEAD_MSB : DMA_DESC_HEAD_HEAD_LSB] =
                                    {{(16-RING_AW){1'b0}}, ring_head_w};
            ADDR_DMA_DESC_TAIL: reg_rdata[DMA_DESC_TAIL_TAIL_MSB : DMA_DESC_TAIL_TAIL_LSB] = r_desc_tail;
            ADDR_DMA_WEIGHT_TILE_LO: reg_rdata = r_wt_base_lo;
            ADDR_DMA_WEIGHT_TILE_HI: begin
                reg_rdata[DMA_WEIGHT_TILE_HI_WT_BASE_HI_MSB : DMA_WEIGHT_TILE_HI_WT_BASE_HI_LSB] = r_wt_base_hi;
                reg_rdata[DMA_WEIGHT_TILE_HI_WT_SHAPE_MSB   : DMA_WEIGHT_TILE_HI_WT_SHAPE_LSB]   = r_wt_shape;
            end
            ADDR_DMA_STATUS: begin
                reg_rdata[DMA_STATUS_RUNNING_LSB]   = walker_running;
                reg_rdata[DMA_STATUS_ARMED_LSB]     = armed_s;
                reg_rdata[DMA_STATUS_WT_LOADED_LSB] = s_wt_loaded;
                reg_rdata[DMA_STATUS_UNDERRUN_LSB]  = dma_underrun_sync;
                reg_rdata[DMA_STATUS_DESC_ERR_LSB]  = walker_desc_err;
                reg_rdata[DMA_STATUS_ROWS_BUFFERED_MSB : DMA_STATUS_ROWS_BUFFERED_LSB] = s_rows_buffered;
                reg_rdata[DMA_STATUS_LAST_DESC_ID_MSB  : DMA_STATUS_LAST_DESC_ID_LSB]  = walker_last_desc_id;
            end
            default: reg_rdata = 32'h0;
        endcase
    end

    // ============================================== descriptor walker
    greencoyote_dma_walker #(
        .N_OPT_CH (N_OPT_CH), .K_TOTAL (K_TOTAL), .OPERAND_BITS (OPERAND_BITS),
        .AXI_ADDR_W (AXI_ADDR_W), .AXI_DATA_W (AXI_DATA_W), .AXI_MAX_BURST (AXI_MAX_BURST),
        .DESC_WORDS (DESC_WORDS), .RING_DEPTH (RING_DEPTH)
    ) u_walker (
        .clk          (user_clk),
        .rst_n        (user_rst_n),
        .dma_en       (r_en),
        .dma_arm      (pulse_arm),
        .dma_abort    (pulse_abort | dma_underrun_sync),
        .ring_src     (r_ring_src),
        .wt_shape     (r_wt_shape),
        .op_precision (op_precision),
        .ring_head    (ring_head_w),
        .ring_head_o  (ring_head_w),
        .ring_tail    (ring_tail_q),
        .ring_rd_en   (ring_rd_en_unused),
        .ring_rd_idx  (ring_rd_idx),
        .ring_rd_desc (ring_mem[ring_rd_idx]),
        .memdesc_req  (),
        .memdesc_addr (),
        .memdesc_valid(1'b0),
        .memdesc_data ({(DESC_WORDS*32){1'b0}}),
        .ring_base    (ring_base_full),
        .brq_valid    (brq_valid),
        .brq_ready    (brq_ready),
        .brq_addr     (brq_addr),
        .brq_len      (brq_len),
        .brq_is_weight(brq_is_weight),
        .brq_dst_bank (brq_dst_bank),
        .brq_dst_word (brq_dst_word),
        .brq_first    (brq_first),
        .brq_last     (brq_last),
        .axi_idle     (axi_idle),
        .dma_running  (walker_running),
        .desc_err     (walker_desc_err),
        .last_desc_id (walker_last_desc_id),
        .irq_desc_done(irq_desc_done)
    );

    // ============================================== AXI master + line buffers
    greencoyote_dma_axi_master #(
        .AXI_DATA_W (AXI_DATA_W), .AXI_ID_W (AXI_ID_W), .AXI_ADDR_W (AXI_ADDR_W),
        .N_OPT_CH (N_OPT_CH), .L_CONTRACT (L_CONTRACT), .OPERAND_BITS (OPERAND_BITS),
        .ACT_BUF_BANKS (ACT_BUF_BANKS), .ACT_BUF_WR_DEPTH (ACT_BUF_WR_DEPTH),
        .WT_BUF_WR_DEPTH (WT_BUF_WR_DEPTH)
    ) u_axi (
        .clk (user_clk), .rst_n (user_rst_n), .rd_clk (opt_clk), .rd_rst_n (opt_rst_n),
        .brq_valid (brq_valid), .brq_ready (brq_ready), .brq_addr (brq_addr),
        .brq_len (brq_len), .brq_is_weight (brq_is_weight), .brq_dst_bank (brq_dst_bank),
        .brq_dst_word (brq_dst_word), .brq_first (brq_first), .brq_last (brq_last),
        .act_arid (act_arid), .act_araddr (act_araddr), .act_arlen (act_arlen),
        .act_arsize (act_arsize), .act_arburst (act_arburst), .act_arcache (act_arcache),
        .act_arprot (act_arprot), .act_arvalid (act_arvalid), .act_arready (act_arready),
        .act_rid (act_rid), .act_rdata (act_rdata), .act_rresp (act_rresp),
        .act_rlast (act_rlast), .act_rvalid (act_rvalid), .act_rready (act_rready),
        .wt_arid (wt_arid), .wt_araddr (wt_araddr), .wt_arlen (wt_arlen),
        .wt_arsize (wt_arsize), .wt_arburst (wt_arburst), .wt_arcache (wt_arcache),
        .wt_arprot (wt_arprot), .wt_arvalid (wt_arvalid), .wt_arready (wt_arready),
        .wt_rid (wt_rid), .wt_rdata (wt_rdata), .wt_rresp (wt_rresp),
        .wt_rlast (wt_rlast), .wt_rvalid (wt_rvalid), .wt_rready (wt_rready),
        .cfg_arcache (r_arcache), .cfg_arprot (r_arprot), .cfg_wt_reload (pulse_wt_reload),
        .act_rd_en (act_rd_en), .act_rd_data (act_operands),
        .wt_rd_col (wt_rd_col), .wt_rd_en (wt_rd_en), .wt_rd_data (wt_operands),
        .rows_buffered (rows_buffered_opt), .wt_loaded (wt_loaded_opt),
        .underrun (underrun_opt), .axi_idle (axi_idle)
    );

    // ============================================== optical-domain fire path
    always_ff @(posedge opt_clk or negedge opt_rst_n) begin
        if (!opt_rst_n) begin
            window_w_m <= '0; window_w_s <= '0;
            r_en_m <= 1'b0;   r_en_opt <= 1'b0;
            wt_rd_col <= 9'd0; act_rd_en <= 1'b0; wt_rd_en <= 1'b0; operand_valid <= 1'b0;
        end else begin
            window_w_m <= r_window_w; window_w_s <= window_w_m;
            r_en_m <= r_en;          r_en_opt <= r_en_m;
            act_rd_en <= 1'b0; wt_rd_en <= 1'b0; operand_valid <= 1'b0;
            if (seq_fire && dma_armed) begin
                act_rd_en     <= 1'b1;
                wt_rd_en      <= 1'b1;
                operand_valid <= 1'b1;
                wt_rd_col     <= (wt_rd_col == 9'(FIRES_PER_WIN-1)) ? 9'd0 : (wt_rd_col + 9'd1);
            end
        end
    end

    assign dma_armed    = (rows_buffered_opt >= window_w_s) && wt_loaded_opt && r_en_opt;
    assign dma_underrun = underrun_opt;

    // ============================================== status back to user_clk
    always_ff @(posedge user_clk or negedge user_rst_n) begin
        if (!user_rst_n) begin
            armed_m <= 1'b0; armed_s <= 1'b0;
            urun_m  <= 1'b0; dma_underrun_sync <= 1'b0;
            rows_m  <= '0;   s_rows_buffered   <= '0;
            wtld_m  <= 1'b0; s_wt_loaded       <= 1'b0;
        end else begin
            armed_m <= dma_armed;         armed_s          <= armed_m;
            urun_m  <= underrun_opt;      dma_underrun_sync <= urun_m;
            rows_m  <= rows_buffered_opt; s_rows_buffered   <= rows_m;   // advisory status
            wtld_m  <= wt_loaded_opt;     s_wt_loaded       <= wtld_m;
        end
    end

    // ============================================== IRQ
    assign irq_dma = (irq_desc_done     & irq_dma_done_en)
                   | (dma_underrun_sync & irq_dma_underrun_en);

`ifndef SYNTHESIS
    initial begin
        assert (L_CONTRACT*FIRES_PER_WIN == K_TOTAL)
            else $error("greencoyote_streaming_dma: L_CONTRACT*FIRES_PER_WIN != K_TOTAL");
        assert (N_OPT_CH*K_TOTAL*OPERAND_BITS/8 == 512*1024)
            else $error("greencoyote_streaming_dma: weight tile != 512 KiB");
        assert ((256*1000 / T_FIRE_PS) == FIRES_PER_WIN)
            else $error("greencoyote_streaming_dma: T_obs / T_fire != FIRES_PER_WIN");
    end
`endif

endmodule
