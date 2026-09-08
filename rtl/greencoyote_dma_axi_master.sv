// =============================================================================
// GreenCoyote-Bay — Streaming Tensor DMA : AXI4 Read Master + CDC Buffers
// Project: ODIN_Bridge / Cascaded Optical Reduction Fabric
// Author:  John A. Green
// Date:    2026-09
// =============================================================================
// Two 512-bit AXI4 read ports (activation + weight), the 300 MHz fabric -> 2 GHz
// optical CDC, and the operand line buffers:
//   activations : 2 x 16 KiB ping-pong        (optical_geometry_spec sec 3.2)
//   weights     : 64 x 8 KiB distributed banks (optical_geometry_spec sec 3.3)
//
// Data RAMs are inferred dual-clock simple-dual-port (write @ fabric clk, read @
// optical clk). Bank-ownership CDC uses greencoyote_cs_lane_fifo (the project's
// Gray-pointer + 2-FF (* ASYNC_REG *) async FIFO) as a 1-bit token channel.
// Every sequential element has an explicit async-low reset value.
//
// Synthesizable SystemVerilog, IEEE 1800-2012.
// =============================================================================

module greencoyote_dma_axi_master #(
    parameter int AXI_DATA_W       = 512,
    parameter int AXI_ID_W         = 4,
    parameter int AXI_ADDR_W       = 48,
    parameter int N_OPT_CH         = 64,
    parameter int L_CONTRACT       = 16,
    parameter int OPERAND_BITS     = 8,
    parameter int ACT_BUF_BANKS    = 2,
    parameter int ACT_BUF_WR_DEPTH = 256,   // 512-bit words per 16 KiB bank
    parameter int WT_BUF_WR_DEPTH  = 128    // 512-bit words per 8 KiB bank
)(
    // ---- fabric domain (user_clk, 300 MHz) : AXI + walker ----
    input  logic                     clk,
    input  logic                     rst_n,
    // ---- optical domain (opt_clk, 2 GHz) : operand read ports ----
    input  logic                     rd_clk,
    input  logic                     rd_rst_n,

    // ---- burst request from greencoyote_dma_walker ----
    input  logic                     brq_valid,
    output logic                     brq_ready,
    input  logic [AXI_ADDR_W-1:0]    brq_addr,
    input  logic [7:0]               brq_len,          // ARLEN (beats-1)
    input  logic                     brq_is_weight,
    input  logic [$clog2(N_OPT_CH)-1:0] brq_dst_bank,
    input  logic [15:0]              brq_dst_word,     // weight: 512-bit word offset in bank
    input  logic                     brq_first,
    input  logic                     brq_last,         // terminal marker: close the window

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

    // ---- AXI attributes (from DMA_CTRL) ----
    input  logic [3:0]               cfg_arcache,
    input  logic [2:0]               cfg_arprot,
    input  logic                     cfg_wt_reload,    // 1-cycle: new DMA_WEIGHT_TILE_HI write

    // ---- operand read ports (optical domain) ----
    input  logic                     act_rd_en,        // one 128-bit activation row per fire
    output logic [L_CONTRACT*OPERAND_BITS-1:0] act_rd_data,
    input  logic [8:0]               wt_rd_col,        // 128-bit slice index within the tile row (0..511)
    input  logic                     wt_rd_en,
    output logic [N_OPT_CH*L_CONTRACT*OPERAND_BITS-1:0] wt_rd_data,  // 64 x 128 bits

    // ---- status ----
    output logic [11:0]              rows_buffered,    // activation rows resident (optical domain)
    output logic                     wt_loaded,        // full 512 KiB tile resident
    output logic                     underrun,         // sticky: read attempted with no data
    output logic                     axi_idle          // no outstanding AR / R
);

    // -------------------------------------------------------------- localparams
    localparam int AXI_BYTES    = AXI_DATA_W/8;                 // 64
    localparam int LOG2_AXIB    = $clog2(AXI_BYTES);            // 6
    localparam int RD_W         = L_CONTRACT*OPERAND_BITS;      // 128
    localparam int SUBW         = AXI_DATA_W/RD_W;              // 4
    localparam int SUBW_AW      = $clog2(SUBW);                 // 2
    localparam int ACT_AW       = $clog2(ACT_BUF_WR_DEPTH);     // 8
    localparam int WT_AW        = $clog2(WT_BUF_WR_DEPTH);      // 7
    localparam int BANK_AW      = $clog2(N_OPT_CH);             // 6
    localparam int ACT_ROWS     = ACT_BUF_WR_DEPTH*SUBW;        // 1024 (128-bit rows / bank)
    localparam int WT_BEATS_ALL = N_OPT_CH*WT_BUF_WR_DEPTH;     // 8192

    // ================================================================= storage
    (* ram_style = "ultra" *) logic [AXI_DATA_W-1:0]
        act_mem [0:ACT_BUF_BANKS-1][0:ACT_BUF_WR_DEPTH-1];
    (* ram_style = "ultra" *) logic [AXI_DATA_W-1:0]
        wt_mem  [0:N_OPT_CH-1][0:WT_BUF_WR_DEPTH-1];

    // ============================================ fabric-domain declarations
    typedef enum logic [1:0] { B_IDLE, B_AR, B_DATA } bstate_t;

    bstate_t             a_st;
    logic [ACT_AW-1:0]   a_wr_word;
    logic                a_fill_sel;
    logic [8:0]          a_beats_left;
    logic                act_bank_ready_push;
    logic [0:0]          act_bank_ready_id;    // id captured BEFORE the ping-pong flip

    bstate_t             w_st;
    logic [BANK_AW-1:0]  w_bank;
    logic [WT_AW-1:0]    w_word;
    logic [8:0]          w_beats_left;
    logic [13:0]         w_beats_total;

    // ============================================ optical-domain declarations
    logic [0:0]          act_rd_bank;
    logic [ACT_AW-1:0]   act_rd_word;
    logic [SUBW_AW-1:0]  act_rd_sub;
    logic [11:0]         act_rows_left;
    logic                act_have_bank;
    logic                act_bank_free_push;
    logic [0:0]          act_bank_free_id;    // drained bank id, captured before re-point

    // ============================================ CDC token FIFOs
    logic       act_bank_ready_full, act_bank_ready_empty, act_bank_ready_pop;
    logic [0:0] act_ready_bank_id;
    logic       act_bank_free_full,  act_bank_free_empty;
    logic [0:0] act_free_bank_id;

    // ------------------------------------------------------- request routing
    wire brq_is_act = brq_valid && !brq_is_weight && !brq_last;
    wire brq_is_wt  = brq_valid &&  brq_is_weight && !brq_last;
    assign brq_ready = brq_last ? (a_st==B_IDLE && w_st==B_IDLE)
                     : brq_is_weight ? (w_st==B_IDLE) : (a_st==B_IDLE);
    assign axi_idle  = (a_st==B_IDLE) && (w_st==B_IDLE);

    // ------------------------------------------------------- AXI static wiring
    assign act_arid    = '0;
    assign act_arsize  = 3'(LOG2_AXIB);
    assign act_arburst = 2'b01;
    assign act_arcache = cfg_arcache;
    assign act_arprot  = cfg_arprot;
    assign act_rready  = (a_st == B_DATA);
    assign wt_arid     = {{(AXI_ID_W-1){1'b0}}, 1'b1};
    assign wt_arsize   = 3'(LOG2_AXIB);
    assign wt_arburst  = 2'b01;
    assign wt_arcache  = cfg_arcache;
    assign wt_arprot   = cfg_arprot;
    assign wt_rready   = (w_st == B_DATA);

    // ============================================ ACT burst engine (fabric)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_st                <= B_IDLE;
            a_wr_word            <= '0;
            a_fill_sel           <= 1'b0;
            a_beats_left         <= '0;
            act_araddr           <= '0;
            act_arlen            <= '0;
            act_arvalid          <= 1'b0;
            act_bank_ready_push  <= 1'b0;
            act_bank_ready_id    <= 1'b0;
        end else begin
            act_bank_ready_push <= 1'b0;
            unique case (a_st)
                B_IDLE: begin
                    if (brq_valid && brq_ready && brq_is_act) begin
                        act_araddr   <= brq_addr;
                        act_arlen    <= brq_len;
                        act_arvalid  <= 1'b1;
                        a_beats_left <= {1'b0, brq_len} + 9'd1;
                        if (brq_first) a_wr_word <= '0;
                        a_st         <= B_AR;
                    end
                end
                B_AR: if (act_arvalid && act_arready) begin
                        act_arvalid <= 1'b0;
                        a_st        <= B_DATA;
                    end
                B_DATA: if (act_rvalid && act_rready) begin
                        act_mem[a_fill_sel][a_wr_word] <= act_rdata;
                        a_beats_left <= a_beats_left - 9'd1;
                        if (act_rlast || a_beats_left == 9'd1) begin
                            a_st <= B_IDLE;
                            if (a_wr_word == ACT_AW'(ACT_BUF_WR_DEPTH-1)) begin
                                act_bank_ready_push <= 1'b1;   // fill bank complete
                                act_bank_ready_id   <= a_fill_sel;   // capture id before flip
                                a_fill_sel <= ~a_fill_sel;
                                a_wr_word  <= '0;
                            end else begin
                                a_wr_word  <= a_wr_word + 1'b1;
                            end
                        end else begin
                            a_wr_word <= a_wr_word + 1'b1;
                        end
                    end
                default: a_st <= B_IDLE;
            endcase
        end
    end

    // ============================================ WT burst engine (fabric)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_st          <= B_IDLE;
            w_bank        <= '0;
            w_word        <= '0;
            w_beats_left  <= '0;
            w_beats_total <= '0;
            wt_araddr     <= '0;
            wt_arlen      <= '0;
            wt_arvalid    <= 1'b0;
            wt_loaded     <= 1'b0;
        end else begin
            if (cfg_wt_reload) begin
                w_beats_total <= '0;
                wt_loaded     <= 1'b0;
            end
            unique case (w_st)
                B_IDLE: begin
                    if (brq_valid && brq_ready && brq_is_wt) begin
                        wt_araddr    <= brq_addr;
                        wt_arlen     <= brq_len;
                        wt_arvalid   <= 1'b1;
                        w_beats_left <= {1'b0, brq_len} + 9'd1;
                        w_bank       <= brq_dst_bank;
                        w_word       <= brq_dst_word[WT_AW-1:0];
                        w_st         <= B_AR;
                    end
                end
                B_AR: if (wt_arvalid && wt_arready) begin
                        wt_arvalid <= 1'b0;
                        w_st       <= B_DATA;
                    end
                B_DATA: if (wt_rvalid && wt_rready) begin
                        wt_mem[w_bank][w_word] <= wt_rdata;
                        w_word       <= w_word + 1'b1;
                        w_beats_left <= w_beats_left - 9'd1;
                        if (!wt_loaded) begin
                            w_beats_total <= w_beats_total + 14'd1;
                            if ((w_beats_total + 14'd1) >= WT_BEATS_ALL[13:0])
                                wt_loaded <= 1'b1;
                        end
                        if (wt_rlast || w_beats_left == 9'd1)
                            w_st <= B_IDLE;
                    end
                default: w_st <= B_IDLE;
            endcase
        end
    end

    // ============================================ CDC token channels
    greencoyote_cs_lane_fifo #(.DATA_W(1), .ADDR_W(2)) u_bank_ready (
        .wr_clk (clk),     .wr_rst_n (rst_n),
        .wr_en  (act_bank_ready_push), .wr_data (act_bank_ready_id), .wr_full (act_bank_ready_full),
        .rd_clk (rd_clk),  .rd_rst_n (rd_rst_n),
        .rd_en  (act_bank_ready_pop),  .rd_data (act_ready_bank_id), .rd_empty (act_bank_ready_empty)
    );
    greencoyote_cs_lane_fifo #(.DATA_W(1), .ADDR_W(2)) u_bank_free (
        .wr_clk (rd_clk),  .wr_rst_n (rd_rst_n),
        .wr_en  (act_bank_free_push), .wr_data (act_bank_free_id), .wr_full (act_bank_free_full),
        .rd_clk (clk),     .rd_rst_n (rst_n),
        .rd_en  (1'b1),               .rd_data (act_free_bank_id), .rd_empty (act_bank_free_empty)
    );

    // ============================================ activation read (optical)
    assign act_bank_ready_pop =
        (!act_have_bank || act_rows_left == 12'd0) && !act_bank_ready_empty;

    always_ff @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            act_rd_bank        <= 1'b0;
            act_rd_word        <= '0;
            act_rd_sub         <= '0;
            act_rows_left      <= '0;
            act_have_bank      <= 1'b0;
            act_bank_free_push <= 1'b0;
            act_bank_free_id   <= 1'b0;
            underrun           <= 1'b0;
            act_rd_data        <= '0;
        end else begin
            act_bank_free_push <= 1'b0;

            if ((!act_have_bank || act_rows_left == 12'd0) && !act_bank_ready_empty) begin
                if (act_have_bank) begin
                    act_bank_free_push <= 1'b1;              // return drained bank
                    act_bank_free_id   <= act_rd_bank;      // capture id before re-point
                end
                act_rd_bank   <= act_ready_bank_id[0];
                act_rd_word   <= '0;
                act_rd_sub    <= '0;
                act_rows_left <= ACT_ROWS[11:0];
                act_have_bank <= 1'b1;
            end

            if (act_rd_en) begin
                if (act_have_bank && act_rows_left != 12'd0) begin
                    act_rd_data   <= act_mem[act_rd_bank][act_rd_word][act_rd_sub*RD_W +: RD_W];
                    act_rows_left <= act_rows_left - 12'd1;
                    if (act_rd_sub == SUBW_AW'(SUBW-1)) begin
                        act_rd_sub  <= '0;
                        act_rd_word <= act_rd_word + 1'b1;
                    end else begin
                        act_rd_sub  <= act_rd_sub + 1'b1;
                    end
                end else begin
                    underrun <= 1'b1;          // sec 4.1: fire with no operands
                end
            end
        end
    end

    // ============================================ weight read (optical, 64 banks)
    wire [WT_AW-1:0]   wt_rd_word = wt_rd_col[WT_AW+SUBW_AW-1 : SUBW_AW];
    wire [SUBW_AW-1:0] wt_rd_sub  = wt_rd_col[SUBW_AW-1:0];
    genvar b;
    generate
        for (b = 0; b < N_OPT_CH; b++) begin : g_wt_rd
            logic [RD_W-1:0] slice_q;
            always_ff @(posedge rd_clk or negedge rd_rst_n) begin
                if (!rd_rst_n)     slice_q <= '0;
                else if (wt_rd_en) slice_q <= wt_mem[b][wt_rd_word][wt_rd_sub*RD_W +: RD_W];
            end
            assign wt_rd_data[b*RD_W +: RD_W] = slice_q;
        end
    endgenerate

    assign rows_buffered = act_rows_left
                         + (act_bank_ready_empty ? 12'd0 : ACT_ROWS[11:0]);

`ifndef SYNTHESIS
    initial begin
        assert (AXI_DATA_W == 512 && RD_W == 128 && SUBW == 4)
            else $error("greencoyote_dma_axi_master: geometry mismatch vs optical_geometry_spec v1.0.0");
        assert (WT_BEATS_ALL == 8192)
            else $error("greencoyote_dma_axi_master: weight tile beat count must be 8192");
    end
`endif

endmodule
