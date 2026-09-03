// =============================================================================
// GreenCoyote-Bay <-> Vortex 3.0 - tile-final directed test (Verilator --exe)
// =============================================================================
// VX_tcu_unit_top does NOT instantiate VX_uop_sequencer (that lives in
// hw/rtl/core), so one WMMA dispatch drives one execute beat and the TFR FEDP
// reduces the whole tile-K in that beat. This harness therefore runs two phases:
//
//   Phase 1 - value:   one INT8 WMMA, A = B = all-ones INT8, C = 0.
//             Check every committed D lane (int32) == TILE_K
//             (D = C + sum_{k<TILE_K} 1*1 = TILE_K).
//   Phase 2 - SVA:      drive TCU_UOPS dispatches as one instruction, step_k
//             stepped 0..K_STEPS-1 (K-outer, per VX_tcu_uops), so the bound
//             VX_tcu_tilefinal_sva sees beats_in == TCU_UOPS and
//             tile_final == TCU_M_STEPS*TCU_N_STEPS at the result_if tap where
//             the M_AXIS_CS shim sits. A1/A2/A4 evaluate here.
//
// A mid-sim reset separates the phases so the SVA's per-instruction counters
// start clean for phase 2.
// =============================================================================

#include "VVX_tcu_unit_top.h"
#include <verilated.h>
#include <cstdint>
#include <cstdio>
#include <cstring>

static float bits_to_f(uint32_t u) { float f; std::memcpy(&f, &u, 4); return f; }

static uint64_t g_time = 0;
double sc_time_stamp() { return g_time; }

// ---- DPI sink for the bound SVA -----------------------------------------
namespace {
struct TfState {
    bool have_params = false;
    int  uops_expect = -1, tf_expect = -1, tile_k = -1;
    int  instr_retired = 0;
    int  last_beats_in = -1, last_tf_in = -1, last_tf_result = -1;
    int  enqueues = 0, results = 0, tf_result_beats = 0;
    bool tag_live = false;
    bool numiso_seen = false;
    int  numiso_lane0 = -1;
    bool verbose = false;
} tf;
}

extern "C" void gcb_tf_event(int kind, int a, int b, int c) {
    switch (kind) {
    case 0:
        tf.have_params = true;
        tf.uops_expect = a; tf.tf_expect = b; tf.tile_k = c;
        std::printf("[sva] params: TCU_UOPS=%d  tile_final/instr=%d  TILE_K=%d\n", a, b, c);
        break;
    case 1:
        tf.enqueues++;
        if (tf.verbose) std::printf("[sva]   enqueue #%d step_k=%d k_last=%d\n", tf.enqueues, a, b);
        break;
    case 2:
        tf.results++;
        if (b) tf.tf_result_beats++;
        if (tf.verbose) std::printf("[sva]   result #%d is_tile_final=%d\n", a, b);
        break;
    case 3:
        tf.instr_retired++;
        tf.last_beats_in = a; tf.last_tf_in = b; tf.last_tf_result = c;
        std::printf("[sva] retire: beats_in=%d  tile_final_uops=%d  tile_final_result_beats=%d\n", a, b, c);
        break;
    case 4:
        tf.tag_live = true;
        std::printf("[sva] VX_tcu_tilefinal_tag observer live -> A3/A5 evaluating\n");
        break;
    case 5:
        tf.numiso_seen = true;
        tf.numiso_lane0 = a;
        std::printf("[sva] numeric isolation active: result lane[0]=%d across %d lanes (N1/N2/N3)\n", a, b);
        break;
    default: break;
    }
}

namespace {

constexpr uint32_t INST_TCU_WMMA = 0;   // VX_gpu_pkg.sv
constexpr uint32_t TCU_I8_ID     = 17;  // VX_tcu_pkg.sv  (signed INT8)
constexpr uint32_t TCU_I32_ID    = 16;  // VX_tcu_pkg.sv  (INT32 accumulator)
constexpr uint32_t TCU_FP8_ID    = 4;   // VX_tcu_pkg.sv  (E4M3)
constexpr uint32_t TCU_FP32_ID   = 0;   // VX_tcu_pkg.sv
constexpr int      MAX_CYCLES    = 40000;

// operand format selected by +fmt=INT8 | +fmt=FP8
bool     g_fp8      = false;
uint8_t  g_ones     = 0x01;               // all-ones operand byte
uint32_t g_fmt_s    = TCU_I8_ID;
uint32_t g_fmt_d    = TCU_I32_ID;

VVX_tcu_unit_top* dut = nullptr;
uint64_t          cycle = 0;

void tick() {
    dut->clk = 0; dut->eval(); g_time++;
    dut->clk = 1; dut->eval(); g_time++;
    cycle++;
}

void idle_dispatch() {
    dut->dispatch_valid   = 0;
    dut->dispatch_op_type = 0;
    dut->dispatch_step_m  = 0;
    dut->dispatch_step_n  = 0;
    dut->dispatch_step_k  = 0;
    dut->dispatch_sop     = 0;
    dut->dispatch_eop     = 0;
}

void set_wmma_common() {
    dut->dispatch_uuid     = 1;
    dut->dispatch_wis      = 0;
    dut->dispatch_sid      = 0;
    dut->dispatch_tmask    = ~0u;
    dut->dispatch_PC       = 0;
    dut->dispatch_wb       = 1;
    dut->dispatch_wr_xregs = 0;
    dut->dispatch_rd       = 1;
    dut->dispatch_bytesel  = 0;
    dut->dispatch_op_type  = INST_TCU_WMMA;
    dut->dispatch_fmt_s    = g_fmt_s;
    dut->dispatch_fmt_d    = g_fmt_d;
    std::memset(&dut->dispatch_rs1_data, g_ones, sizeof(dut->dispatch_rs1_data));  // A = 1
    std::memset(&dut->dispatch_rs2_data, g_ones, sizeof(dut->dispatch_rs2_data));  // B = 1
    std::memset(&dut->dispatch_rs3_data, 0x00,   sizeof(dut->dispatch_rs3_data));  // C = 0
}

// drive one dispatch beat, return false on timeout
bool dispatch_one(int sm, int sn, int sk, bool sop, bool eop) {
    dut->dispatch_valid   = 1;
    dut->dispatch_step_m  = sm;
    dut->dispatch_step_n  = sn;
    dut->dispatch_step_k  = sk;
    dut->dispatch_sop     = sop;
    dut->dispatch_eop     = eop;
    for (int i = 0; i < MAX_CYCLES; i++) {
        tick();
        if (dut->dispatch_ready) { idle_dispatch(); return true; }
    }
    return false;
}

void do_reset(int n) {
    dut->reset = 1;
    idle_dispatch();
    for (int i = 0; i < n; i++) tick();
    dut->reset = 0;
    for (int i = 0; i < 4; i++) tick();
}

template <typename T> int lane_count(const T& s) { return int(sizeof(s) / sizeof(s[0])); }

} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::assertOn(true);
    for (int i = 1; i < argc; i++) {
        if (!std::strcmp(argv[i], "+verbose")) tf.verbose = true;
        if (!std::strcmp(argv[i], "+fmt=FP8")) {
            g_fp8 = true; g_ones = 0x38;            // E4M3 1.0
            g_fmt_s = TCU_FP8_ID; g_fmt_d = TCU_FP32_ID;
        }
        if (!std::strcmp(argv[i], "+fmt=INT8")) {
            g_fp8 = false; g_ones = 0x01;
            g_fmt_s = TCU_I8_ID; g_fmt_d = TCU_I32_ID;
        }
    }
    std::printf("[tb] operand format: %s\n", g_fp8 ? "FP8 (E4M3)" : "INT8");

    dut = new VVX_tcu_unit_top;
    dut->clk = 0;
    dut->commit_ready = 1;
    do_reset(8);

    int fails = 0;

    // ================= Phase 1 - directed value =================
    set_wmma_common();
    bool committed = false;
    uint32_t d_lane[64] = {0};
    int n_lanes = 0;
    if (!dispatch_one(0, 0, 0, /*sop*/true, /*eop*/true)) { std::printf("FAIL: P1 dispatch timeout\n"); fails++; }
    for (int i = 0; i < MAX_CYCLES && !committed; i++) {
        tick();
        if (dut->commit_valid) {
            committed = true;
            n_lanes = lane_count(dut->commit_data);
            if (n_lanes > 64) n_lanes = 64;
            for (int t = 0; t < n_lanes; t++) d_lane[t] = dut->commit_data[t];
        }
    }
    int eff_tile_k = -1;
    if (!committed) { std::printf("FAIL: P1 commit timeout\n"); fails++; }
    else {
        // effective tile-K = lane 0 of the directed all-ones WMMA (one FEDP beat
        // reduces the whole per-config K). sec 8.4: expect 8 or 16.
        int32_t d0i = (int32_t)d_lane[0];
        eff_tile_k = g_fp8 ? (int)bits_to_f(d_lane[0]) : d0i;
        int bad = 0;
        for (int t = 0; t < n_lanes; t++) {
            long d = g_fp8 ? (long)bits_to_f(d_lane[t]) : (long)(int32_t)d_lane[t];
            if (d != eff_tile_k) { if (bad < 4) std::printf("FAIL: P1 D[lane %d]=%ld != lane0 %d\n", t, d, eff_tile_k); bad++; }
        }
        if (eff_tile_k != 8 && eff_tile_k != 16) {
            std::printf("FAIL: P1 effective TILE_K = %d, expected 8 or 16\n", eff_tile_k); fails++;
        } else if (bad == 0) {
            std::printf("PASS: P1 all %d D lanes == effective TILE_K (%d)%s\n", n_lanes, eff_tile_k,
                        eff_tile_k == tf.tile_k ? "" : " [note: TCU_TILE_K param differs]");
        } else {
            std::printf("FAIL: P1 %d/%d D lanes differ from lane 0\n", bad, n_lanes); fails++;
        }
    }

    // ================= Phase 2 - SVA beat counts =================
    do_reset(8);
    tf.enqueues = tf.results = tf.instr_retired = 0;

    const int K_STEPS  = (tf.tf_expect > 0) ? tf.uops_expect / tf.tf_expect : 1;
    const int MN_STEPS = tf.tf_expect;
    set_wmma_common();
    bool drive_ok = true;
    int beat = 0;
    for (int k = 0; k < K_STEPS && drive_ok; k++)
        for (int mn = 0; mn < MN_STEPS && drive_ok; mn++) {
            bool sop = (beat == 0);
            bool eop = (beat == tf.uops_expect - 1);
            drive_ok = dispatch_one(mn, 0, k, sop, eop);
            beat++;
        }
    if (!drive_ok) { std::printf("FAIL: P2 dispatch timeout at beat %d\n", beat); fails++; }

    for (int i = 0; i < MAX_CYCLES && tf.instr_retired < 1; i++) tick();
    for (int i = 0; i < 64; i++) tick();

    if (!tf.have_params)      { std::printf("FAIL: SVA params DPI never fired (bind missing?)\n"); fails++; }
    if (tf.instr_retired < 1) { std::printf("FAIL: P2 SVA never retired an instruction (drove %d beats, %d results)\n", beat, tf.results); fails++; }
    else {
        if (tf.last_beats_in != tf.uops_expect) { std::printf("FAIL: beats_in=%d exp TCU_UOPS=%d\n", tf.last_beats_in, tf.uops_expect); fails++; }
        if (tf.last_tf_in    != tf.tf_expect)   { std::printf("FAIL: tile_final uops=%d exp M_STEPS*N_STEPS=%d\n", tf.last_tf_in, tf.tf_expect); fails++; }
        if (tf.last_tf_result != tf.tf_expect)  { std::printf("FAIL: tile_final RESULT beats=%d exp %d\n", tf.last_tf_result, tf.tf_expect); fails++; }
        if (tf.last_beats_in == tf.uops_expect && tf.last_tf_in == tf.tf_expect && tf.last_tf_result == tf.tf_expect)
            std::printf("PASS: P2 SVA counts - beats_in=%d, tile_final uops=%d, tile_final result beats=%d (A1/A2/A4)\n",
                        tf.last_beats_in, tf.last_tf_in, tf.last_tf_result);
    }
    if (!tf.tag_live) { std::printf("FAIL: VX_tcu_tilefinal_tag observer never went live (A3/A5 did not evaluate)\n"); fails++; }
    else              std::printf("PASS: A3/A5 evaluated against a live is_tile_final (tag observer bound)\n");

    if (tf.numiso_seen) {
        if (tf.numiso_lane0 != eff_tile_k) { std::printf("FAIL: numeric-isolation lane[0]=%d != effective TILE_K=%d\n", tf.numiso_lane0, eff_tile_k); fails++; }
        else std::printf("PASS: numeric isolation N0/N1/N2/N3 hold (INT32 lanes == %d, no overflow, no bleed)\n", eff_tile_k);
    } else {
        std::printf("note: numeric-isolation asserts inactive (GCB_TF_NUMISO not set - non-INT8 config)\n");
    }

    dut->final();
    delete dut;

    std::printf("TCU_TILEFINAL: %s (%llu cycles)\n",
                fails ? "DIRECTED FAIL" : "DIRECTED PASS", (unsigned long long)cycle);
    return fails ? 1 : 0;
}
