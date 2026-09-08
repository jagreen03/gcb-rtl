// =============================================================================
// GreenCoyote-Bay — Streaming Tensor DMA : Descriptor Walker FSM
// Project: ODIN_Bridge / Cascaded Optical Reduction Fabric
// Author:  John A. Green
// Date:    2026-09
// =============================================================================
// Walks 32-byte tensor descriptors and emits 4 KiB-aligned AXI4 INCR burst
// requests to greencoyote_dma_axi_master. One of the three inbound-DMA modules
// (walker / axi_master / top). Architecture:
//   gcb-spec/docs/streaming_dma_architecture.md   (sec 2.2 descriptor, sec 6)
//   gcb-spec/docs/optical_geometry_spec.md        (v1.0.0 LOCKED localparams)
// Register block: gcb-spec/registers.yaml DMA 0xC4-0xE4 (map_version 0.6.0).
//
// Descriptor (32 B, little-endian, 8 x 32-bit words), streaming_dma sec 2.2:
//   [ 47:  0] base_addr        byte address of element (0,0)
//   [ 51: 48] elem_log2_bytes  0 = 1/2 B (packed nibble), 1 = 1 B, 2 = 2 B, ...
//   [ 67: 52] inner_extent     elements per row
//   [ 99: 68] inner_stride     byte stride between elements (== elem_bytes => packed)
//   [115:100] outer_extent     number of rows
//   [147:116] outer_stride     byte stride between rows (row pitch)
//   [155:148] pad_before       zero-fill rows/elements prepended  (read-side, v2)
//   [163:156] pad_after        zero-fill rows/elements appended   (read-side, v2)
//   [175:164] batch_extent     3rd dim (tiles reusing the weight buffer)
//   [207:176] batch_stride     byte stride between batch planes
//   [223:208] flags   bit0 LAST  bit1 IRQ_ON_DONE  bit2 WEIGHT(1)/ACT(0)
//                     bit3 PRELOAD (fill, do not fire)   [7:4] PRECISION
//   [255:224] reserved / CRC   (CRC check is a v2 item)
//
// Synthesizable SystemVerilog, IEEE 1800-2012. Explicit active-low reset,
// single fabric clock domain (user_clk, 300 MHz). No CDC in this module.
// =============================================================================

module greencoyote_dma_walker #(
    parameter int N_OPT_CH      = 64,
    parameter int K_TOTAL       = 8192,
    parameter int OPERAND_BITS  = 8,
    parameter int AXI_ADDR_W    = 48,
    parameter int AXI_DATA_W    = 512,
    parameter int AXI_MAX_BURST = 256,     // INCR beats
    parameter int DESC_WORDS    = 8,       // 32-byte descriptor / 4
    parameter int RING_DEPTH    = 32       // on-die descriptor ring entries
)(
    input  logic                     clk,
    input  logic                     rst_n,

    // ---- control (decoded from the DMA_* register block by the top) ----
    input  logic                     dma_en,        // DMA_CTRL.EN
    input  logic                     dma_arm,       // DMA_CTRL.ARM  (1-cycle)
    input  logic                     dma_abort,     // DMA_CTRL.ABORT (1-cycle)
    input  logic                     ring_src,      // DMA_CTRL.RING_SRC 0=on-die 1=in-mem
    input  logic [3:0]               wt_shape,      // DMA_WEIGHT_TILE_HI.WT_SHAPE
    input  logic [2:0]               op_precision,  // PRECISION_MODE.MODE_SEL mirror

    // ---- on-die descriptor ring (assembled by the top from DMA_DESC_WINDOW) ----
    input  logic [$clog2(RING_DEPTH)-1:0]  ring_head,   // consumer index (this module drives)
    output logic [$clog2(RING_DEPTH)-1:0]  ring_head_o,
    input  logic [$clog2(RING_DEPTH)-1:0]  ring_tail,   // producer index (doorbell)
    output logic                           ring_rd_en,
    output logic [$clog2(RING_DEPTH)-1:0]  ring_rd_idx,
    input  logic [DESC_WORDS*32-1:0]       ring_rd_desc, // 256-bit descriptor, comb read

    // ---- in-memory descriptor fetch (ring_src = 1); serviced by axi_master ----
    output logic                     memdesc_req,
    output logic [AXI_ADDR_W-1:0]    memdesc_addr,
    input  logic                     memdesc_valid,
    input  logic [DESC_WORDS*32-1:0] memdesc_data,
    input  logic [AXI_ADDR_W-1:0]    ring_base,      // DMA_DESC_RING_BASE_{LO,HI}

    // ---- burst request to greencoyote_dma_axi_master ----
    output logic                     brq_valid,
    input  logic                     brq_ready,
    output logic [AXI_ADDR_W-1:0]    brq_addr,
    output logic [7:0]               brq_len,        // AXI ARLEN (beats - 1)
    output logic                     brq_is_weight,
    output logic [$clog2(N_OPT_CH)-1:0] brq_dst_bank, // weight bank (channel)
    output logic [15:0]              brq_dst_word,    // 512-bit word offset within the bank
    output logic                     brq_first,       // first burst of a descriptor
    output logic                     brq_last,        // last burst of the current window

    // ---- status ----
    input  logic                     axi_idle,        // axi_master has no outstanding AR/R
    output logic                     dma_running,
    output logic                     desc_err,        // sticky: malformed descriptor
    output logic [11:0]              last_desc_id,
    output logic                     irq_desc_done    // 1-cycle at window completion
);

    // ------------------------------------------------------------------ derived
    localparam int AXI_BYTES    = AXI_DATA_W/8;                  // 64
    localparam int LOG2_AXIB    = $clog2(AXI_BYTES);             // 6
    localparam int PAGE_BYTES   = 4096;
    localparam int RING_AW      = $clog2(RING_DEPTH);
    localparam int WT_BANK_BYTES= K_TOTAL*OPERAND_BITS/8;        // 8192
    localparam int WT_BANK_WORDS= WT_BANK_BYTES/AXI_BYTES;       // 128

    // WT_SHAPE table (v1: only shape 0 defined = full 64 x K_TOTAL tile).
    localparam logic [3:0] WT_SHAPE_FULL = 4'd0;

    // ------------------------------------------------------------- descriptor fields
    // Bit layout: streaming_dma_architecture.md sec 2.2 (sums to 256).
    logic [DESC_WORDS*32-1:0] d;                 // latched descriptor
    wire [AXI_ADDR_W-1:0] d_base      = d[47:0];
    wire [3:0]            d_elog2     = d[51:48];
    wire [15:0]           d_inner_ext = d[67:52];
    wire [31:0]           d_inner_str = d[99:68];
    wire [15:0]           d_outer_ext = d[115:100];
    wire [31:0]           d_outer_str = d[147:116];
    wire [7:0]            d_pad_before= d[155:148];   // read-side zero-fill (v2)
    wire [7:0]            d_pad_after = d[163:156];   // read-side zero-fill (v2)
    wire [11:0]           d_batch_ext = d[175:164];
    wire [31:0]           d_batch_str_w = d[207:176];
    wire [15:0]           d_flags     = d[223:208];
    wire        f_last     = d_flags[0];
    wire        f_irq      = d_flags[1];
    wire        f_weight   = d_flags[2];
    wire        f_preload  = d_flags[3];       // PRELOAD: fill, do not fire (top honours it)
    wire [3:0]  f_prec     = d_flags[7:4];

    // elem_log2_bytes encoding (streaming_dma_architecture.md sec 2.2):
    //   0 = 1/2 B (packed nibble) ; 1 = 1 B ; 2 = 2 B ; 3 = 4 B ; ...
    // Address math uses whole-byte granularity; a packed-nibble run (elog2 = 0)
    // is addressed at 1 B per 2 elements -> approximate here, exact packing is a
    // read-side concern (v2).
    wire [31:0] elem_bytes = (d_elog2 == 4'd0) ? 32'd1 : (32'd1 << (d_elog2 - 4'd1));
    wire [AXI_ADDR_W-1:0] row_bytes = (d_elog2 == 4'd0)
                                    ? {1'b0, d_inner_ext[15:1]}          // 1/2 B/elem
                                    : (d_inner_ext * elem_bytes);

    // --------------------------------------------------------------------- FSM
    typedef enum logic [2:0] {
        S_IDLE, S_FETCH, S_DECODE, S_ADDR, S_BRQ, S_NEXTROW, S_DESCDONE, S_WINDONE
    } state_t;
    state_t st;

    logic [15:0]              row_i;      // current row (0 .. outer_ext-1)
    logic [15:0]              batch_i;    // current batch plane
    logic [AXI_ADDR_W-1:0]    row_base;   // byte address of the current row
    logic [AXI_ADDR_W-1:0]    cur_addr;   // running address within the row
    logic [AXI_ADDR_W-1:0]    row_end;    // row_base + row_bytes
    logic [15:0]              wt_word_acc;// running 512-bit word offset for a weight bank
    logic                     first_burst;
    logic [RING_AW-1:0]       head_q;

    // bytes to the next 4 KiB page boundary from cur_addr
    wire [12:0] to_page = 13'(PAGE_BYTES - (cur_addr[11:0]));
    // bytes remaining in this row
    wire [AXI_ADDR_W-1:0] row_rem = row_end - cur_addr;
    // burst length in bytes: min(row_rem, to_page, AXI_MAX_BURST*AXI_BYTES),
    // then floor to a whole number of beats
    wire [31:0] cap_max  = AXI_MAX_BURST*AXI_BYTES;
    wire [31:0] b_bytes0 = (row_rem  < cap_max ) ? row_rem[31:0] : cap_max;
    wire [31:0] b_bytes1 = (to_page  < b_bytes0) ? {19'd0,to_page} : b_bytes0;
    wire [31:0] b_beats  = (b_bytes1 + AXI_BYTES - 1) >> LOG2_AXIB;  // ceil
    wire [7:0]  b_len    = (b_beats == 0) ? 8'd0 : 8'(b_beats - 1);

    assign ring_head_o  = head_q;
    assign ring_rd_idx  = head_q;
    assign dma_running  = (st != S_IDLE);
    assign last_desc_id = {{(12-RING_AW){1'b0}}, head_q};

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st           <= S_IDLE;
            d            <= '0;
            row_i        <= '0;
            batch_i      <= '0;
            row_base     <= '0;
            cur_addr     <= '0;
            row_end      <= '0;
            wt_word_acc  <= '0;
            first_burst  <= 1'b0;
            head_q       <= '0;
            brq_valid    <= 1'b0;
            brq_addr     <= '0;
            brq_len      <= '0;
            brq_is_weight<= 1'b0;
            brq_dst_bank <= '0;
            brq_dst_word <= '0;
            brq_first    <= 1'b0;
            brq_last     <= 1'b0;
            ring_rd_en   <= 1'b0;
            memdesc_req  <= 1'b0;
            memdesc_addr <= '0;
            desc_err     <= 1'b0;
            irq_desc_done<= 1'b0;
        end else begin
            irq_desc_done <= 1'b0;
            ring_rd_en    <= 1'b0;
            memdesc_req   <= 1'b0;

            if (dma_abort) begin
                st        <= S_IDLE;
                brq_valid <= 1'b0;
                head_q    <= ring_head;      // resync to the register view
            end else begin
                unique case (st)
                // -------------------------------------------------------------
                S_IDLE: begin
                    brq_valid <= 1'b0;
                    head_q    <= ring_head;
                    if (dma_en && (dma_arm || (ring_tail != ring_head))) begin
                        if (ring_src) begin
                            memdesc_req  <= 1'b1;
                            memdesc_addr <= ring_base + (AXI_ADDR_W'(head_q) << 5); // *32
                        end else begin
                            ring_rd_en <= 1'b1;   // comb read presents ring_rd_desc next cycle
                        end
                        st <= S_FETCH;
                    end
                end
                // -------------------------------------------------------------
                S_FETCH: begin
                    if (ring_src) begin
                        if (memdesc_valid) begin d <= memdesc_data; st <= S_DECODE; end
                    end else begin
                        d  <= ring_rd_desc;      // registered capture of the comb ring read
                        st <= S_DECODE;
                    end
                end
                // -------------------------------------------------------------
                S_DECODE: begin
                    row_i   <= '0;
                    batch_i <= '0;
                    first_burst <= 1'b1;
                    wt_word_acc <= '0;
                    // validation
                    if (f_weight && (wt_shape != WT_SHAPE_FULL)) begin
                        desc_err <= 1'b1;  st <= S_DESCDONE;
                    end else if (f_weight && (d_outer_ext != N_OPT_CH[15:0])) begin
                        desc_err <= 1'b1;  st <= S_DESCDONE;
                    end else if (f_weight && (row_bytes != AXI_ADDR_W'(WT_BANK_BYTES))) begin
                        desc_err <= 1'b1;  st <= S_DESCDONE;
                    end else if ({1'b0,f_prec} != {2'b00,op_precision}) begin
                        desc_err <= 1'b1;  st <= S_DESCDONE;   // precision mismatch vs PRECISION_MODE
                    end else if (d_inner_ext == 0 || d_outer_ext == 0) begin
                        desc_err <= 1'b1;  st <= S_DESCDONE;
                    end else begin
                        row_base <= d_base;
                        cur_addr <= d_base;
                        row_end  <= d_base + row_bytes;
                        st       <= S_ADDR;
                    end
                end
                // -------------------------------------------------------------
                S_ADDR: begin
                    // present the next burst request
                    brq_valid     <= 1'b1;
                    brq_addr      <= cur_addr;
                    brq_len       <= b_len;
                    brq_is_weight <= f_weight;
                    brq_dst_bank  <= f_weight ? row_i[$clog2(N_OPT_CH)-1:0] : '0;
                    brq_dst_word  <= f_weight ? wt_word_acc : 16'd0; // act: axi_master owns the offset
                    brq_first     <= first_burst;
                    brq_last      <= 1'b0;
                    st            <= S_BRQ;
                end
                // -------------------------------------------------------------
                S_BRQ: begin
                    if (brq_valid && brq_ready) begin
                        brq_valid   <= 1'b0;
                        first_burst <= 1'b0;
                        cur_addr    <= cur_addr + ((b_len + 1) << LOG2_AXIB);
                        if (f_weight)
                            wt_word_acc <= wt_word_acc + (b_len + 1);
                        // more of this row?
                        if ((cur_addr + ((b_len + 1) << LOG2_AXIB)) < row_end)
                            st <= S_ADDR;
                        else
                            st <= S_NEXTROW;
                    end
                end
                // -------------------------------------------------------------
                S_NEXTROW: begin
                    if (row_i + 1 < d_outer_ext) begin
                        row_i       <= row_i + 1;
                        row_base    <= row_base + d_outer_str;
                        cur_addr    <= row_base + d_outer_str;
                        row_end     <= row_base + d_outer_str + row_bytes;
                        wt_word_acc <= '0;              // each weight row starts a fresh bank
                        first_burst <= 1'b1;
                        st          <= S_ADDR;
                    end else if (batch_i + 1 < d_batch_ext) begin
                        batch_i     <= batch_i + 1;
                        row_i       <= '0;
                        row_base    <= d_base + ((batch_i + 1) * d_batch_str_w);
                        cur_addr    <= d_base + ((batch_i + 1) * d_batch_str_w);
                        row_end     <= d_base + ((batch_i + 1) * d_batch_str_w) + row_bytes;
                        wt_word_acc <= '0;
                        first_burst <= 1'b1;
                        st          <= S_ADDR;
                    end else begin
                        st <= S_DESCDONE;
                    end
                end
                // -------------------------------------------------------------
                S_DESCDONE: begin
                    head_q <= head_q + 1'b1;
                    if (f_last || ((head_q + 1'b1) == ring_tail) || desc_err)
                        st <= S_WINDONE;
                    else begin
                        // fetch the next descriptor
                        if (ring_src) begin
                            memdesc_req  <= 1'b1;
                            memdesc_addr <= ring_base + (AXI_ADDR_W'(head_q + 1'b1) << 5);
                        end else begin
                            ring_rd_en <= 1'b1;
                        end
                        st <= S_FETCH;
                    end
                end
                // -------------------------------------------------------------
                S_WINDONE: begin
                    if (axi_idle) begin
                        if (f_irq) irq_desc_done <= 1'b1;
                        // emit a terminal marker so the axi_master can close the window
                        brq_valid     <= 1'b1;
                        brq_last      <= 1'b1;
                        brq_len       <= 8'd0;
                        brq_is_weight <= 1'b0;
                        if (brq_ready) begin
                            brq_valid <= 1'b0;
                            brq_last  <= 1'b0;
                            st        <= S_IDLE;
                        end
                    end
                end
                default: st <= S_IDLE;
                endcase
            end
        end
    end

    // -------------------------------------------------------- elaboration checks
`ifndef SYNTHESIS
    initial begin
        assert (AXI_DATA_W == 512)
            else $error("greencoyote_dma_walker: AXI_DATA_W must be 512 (optical_geometry_spec v1.0.0)");
        assert (WT_BANK_BYTES == 8192)
            else $error("greencoyote_dma_walker: K_TOTAL*OPERAND_BITS/8 must be 8192");
    end
`endif

endmodule
