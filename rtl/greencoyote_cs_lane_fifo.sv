// =============================================================================
// GreenCoyote-Bay — Carry-Save Lane FIFO (dual-clock)
// Project: ODIN_Bridge / Cascaded Optical Reduction Fabric
// =============================================================================
// One asynchronous (dual-clock) FIFO per optical reduction lane — the
// "buffer-halt buffer" of carry_save_streaming_contract.md sec 6.3. Absorbs the
// per-unit completion skew between a Vortex TCU block (write side, core_clk) and
// the pilot photonic sequencer (read side, user_clk). No clock relationship is
// assumed between the two domains.
//
// Standard Gray-pointer design: binary -> Gray pointer conversion, 2-FF pointer
// synchronisers with (* ASYNC_REG *) on the meta stage, one extra address bit to
// distinguish full from empty. First-word-fall-through read: rd_data is the head
// entry whenever rd_empty is low; rd_en advances the read pointer.
//
// DEPTH = 2**ADDR_W. Contract sec 6.3: minimum 2 records, recommended 4.
// =============================================================================

module greencoyote_cs_lane_fifo #(
    parameter int DATA_W = 32,
    parameter int ADDR_W = 2               // DEPTH = 4
)(
    // ---- write domain (Vortex core_clk) ----
    input  logic                 wr_clk,
    input  logic                 wr_rst_n,
    input  logic                 wr_en,
    input  logic [DATA_W-1:0]    wr_data,
    output logic                 wr_full,

    // ---- read domain (pilot user_clk) ----
    input  logic                 rd_clk,
    input  logic                 rd_rst_n,
    input  logic                 rd_en,
    output logic [DATA_W-1:0]    rd_data,
    output logic                 rd_empty
);

    localparam int DEPTH = (1 << ADDR_W);

    // Storage — inferred dual-port RAM, independent r/w clocks.
    logic [DATA_W-1:0] mem [0:DEPTH-1];

    // Pointers carry one extra MSB (wrap bit) for full/empty disambiguation.
    logic [ADDR_W:0] wr_bin, wr_gray;
    logic [ADDR_W:0] rd_bin, rd_gray;

    wire [ADDR_W-1:0] wr_addr = wr_bin[ADDR_W-1:0];
    wire [ADDR_W-1:0] rd_addr = rd_bin[ADDR_W-1:0];

    // Cross-domain synchronised copies of the opposite pointer.
    (* ASYNC_REG = "TRUE" *) logic [ADDR_W:0] wr_gray_meta, wr_gray_sync;  // in rd_clk
    (* ASYNC_REG = "TRUE" *) logic [ADDR_W:0] rd_gray_meta, rd_gray_sync;  // in wr_clk

    function automatic logic [ADDR_W:0] bin2gray(input logic [ADDR_W:0] b);
        bin2gray = b ^ (b >> 1);
    endfunction

    // -------------------------------------------------------------------------
    // Write domain
    // -------------------------------------------------------------------------
    wire            wr_do       = wr_en && !wr_full;
    wire [ADDR_W:0] wr_bin_nxt  = wr_bin + (wr_do ? 1'b1 : 1'b0);
    wire [ADDR_W:0] wr_gray_nxt = bin2gray(wr_bin_nxt);

    // full: next write Gray == read Gray with the top two bits inverted.
    wire wr_full_nxt = (wr_gray_nxt ==
                        {~rd_gray_sync[ADDR_W:ADDR_W-1], rd_gray_sync[ADDR_W-2:0]});

    always_ff @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wr_bin       <= '0;
            wr_gray      <= '0;
            wr_full      <= 1'b0;
            rd_gray_meta <= '0;
            rd_gray_sync <= '0;
        end else begin
            if (wr_do) mem[wr_addr] <= wr_data;
            wr_bin       <= wr_bin_nxt;
            wr_gray      <= wr_gray_nxt;
            wr_full      <= wr_full_nxt;
            rd_gray_meta <= rd_gray;
            rd_gray_sync <= rd_gray_meta;
        end
    end

    // -------------------------------------------------------------------------
    // Read domain — first-word-fall-through
    // -------------------------------------------------------------------------
    wire            rd_do       = rd_en && !rd_empty;
    wire [ADDR_W:0] rd_bin_nxt  = rd_bin + (rd_do ? 1'b1 : 1'b0);
    wire [ADDR_W:0] rd_gray_nxt = bin2gray(rd_bin_nxt);

    // empty: next read Gray == synchronised write Gray.
    wire rd_empty_nxt = (rd_gray_nxt == wr_gray_sync);

    always_ff @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_bin       <= '0;
            rd_gray      <= '0;
            rd_empty     <= 1'b1;
            wr_gray_meta <= '0;
            wr_gray_sync <= '0;
        end else begin
            rd_bin       <= rd_bin_nxt;
            rd_gray      <= rd_gray_nxt;
            rd_empty     <= rd_empty_nxt;
            wr_gray_meta <= wr_gray;
            wr_gray_sync <= wr_gray_meta;
        end
    end

    assign rd_data = mem[rd_addr];

endmodule
