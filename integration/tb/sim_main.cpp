// =============================================================================
// GreenCoyote-Bay <-> Vortex 3.0 — tile-final SVA harness (Verilator --exe)
// =============================================================================
// Minimal driver for VX_tcu_unit_top: reset, issue ONE INST_TCU_WMMA dispatch
// (single packet; the RTL expands it to TCU_UOPS uops internally), wait for
// commit. The A1..A5 checks run inside VX_tcu_tilefinal_sva, bound into every
// VX_tcu_core by VX_tcu_tilefinal_sva_bind.sv.
//
// No softfloat / numeric reference here — this harness exists to (a) elaborate
// VX_tcu_core with real interface structs so the bind resolves, and (b) drive
// one instruction so the SVA's per-instruction properties evaluate. Numeric
// correctness of the WMMA is covered by Vortex's own hw/unittest/tcu_unit.
// =============================================================================

#include "VVX_tcu_unit_top.h"
#include <verilated.h>
#include <cstdint>
#include <cstdio>
#include <cstring>

static uint64_t g_time = 0;
double sc_time_stamp() { return g_time; }

namespace {

constexpr uint32_t INST_TCU_WMMA = 0;   // VX_gpu_pkg.sv
constexpr int      MAX_CYCLES    = 20000;

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

} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::assertOn(true);
    dut = new VVX_tcu_unit_top;

    dut->clk = 0;
    dut->reset = 1;
    idle_dispatch();
    dut->commit_ready = 1;
    for (int i = 0; i < 6; i++) tick();
    dut->reset = 0;
    for (int i = 0; i < 4; i++) tick();

    // ---- one WMMA dispatch packet ----
    dut->dispatch_valid    = 1;
    dut->dispatch_uuid     = 1;
    dut->dispatch_wis      = 0;
    dut->dispatch_sid      = 0;
    dut->dispatch_tmask    = ~0u;          // all threads active
    dut->dispatch_PC       = 0;
    dut->dispatch_wb       = 1;
    dut->dispatch_wr_xregs = 0;
    dut->dispatch_rd       = 1;
    dut->dispatch_bytesel  = 0;
    dut->dispatch_op_type  = INST_TCU_WMMA;
    dut->dispatch_fmt_s    = 0;            // fmt index 0
    dut->dispatch_fmt_d    = 0;
    dut->dispatch_step_m   = 0;
    dut->dispatch_step_n   = 0;
    dut->dispatch_step_k   = 0;
    dut->dispatch_sop      = 1;
    dut->dispatch_eop      = 1;
    std::memset(&dut->dispatch_rs1_data, 0x11, sizeof(dut->dispatch_rs1_data));
    std::memset(&dut->dispatch_rs2_data, 0x01, sizeof(dut->dispatch_rs2_data));
    std::memset(&dut->dispatch_rs3_data, 0x00, sizeof(dut->dispatch_rs3_data));

    bool dispatched = false, committed = false;
    for (int i = 0; i < MAX_CYCLES && !committed; i++) {
        tick();
        if (!dispatched && dut->dispatch_ready) {
            dispatched = true;
            idle_dispatch();
        }
        if (dispatched && dut->commit_valid) committed = true;
    }
    for (int i = 0; i < 32; i++) tick();   // flush SVA end-of-instruction checks

    dut->final();
    delete dut;

    if (!dispatched) { std::printf("TCU_TILEFINAL: FAIL — dispatch never accepted\n"); return 1; }
    if (!committed)  { std::printf("TCU_TILEFINAL: FAIL — commit never asserted\n");   return 1; }
    std::printf("TCU_TILEFINAL: WMMA committed after %llu cycles; SVA (A1..A5) ran\n",
                (unsigned long long)cycle);
    return 0;
}
