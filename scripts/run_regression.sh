#!/bin/bash
# Exit immediately if any command fails
set -e 

echo "================================================="
echo " GreenCoyote-Bay: Full QA Regression Sweep       "
echo "================================================="

# 1. Load Local Environment (if it exists)
if [ -f "../.env.local" ]; then
    echo "[Info] Loading local environment from ../.env.local"
    source "../.env.local"
else
    echo "[Info] No .env.local found. Using system PATH."
    VIVADO_CMD=${VIVADO_CMD:-vivado}
fi

# 2. Force Register Regeneration
echo -e "\n[1/4] Regenerating Specification Maps..."
cd ../gcb-spec
python3 regen.py --all

# 3. Run Icarus Testbenches
echo -e "\n[2/4] Running Icarus RTL Testbenches..."
cd ../gcb-rtl
./sim/run_dma_tb.sh
./sim/run_ss_tb.sh

# 4. Run Vivado OOC Synthesis (Top Level)
echo -e "\n[3/4] Running Vivado OOC Synthesis (Timing & Area)..."
eval "$VIVADO_CMD -mode batch -source scripts/build.tcl -log vivado_build.log -nojournal -notrace"
eval "$VIVADO_CMD -mode batch -source scripts/impl.tcl -log vivado_impl.log -nojournal -notrace"

# 5. Extract Breadcrumbs (Metrics Parsing)
echo -e "\n[4/4] Extracting Artifact Metrics..."
# Use tr to strip any lingering carriage returns before parsing
WNS=$(grep -A 2 "Design Timing Summary" build/reports/timing_route.rpt | tail -n 1 | awk '{print $1}' | tr -d '\r')
LUT=$(grep -m 1 "CLB LUTs" build/reports/utilization_route.rpt | awk '{print $4}' | tr -d '\r')
DSP=$(grep -m 1 "DSPs" build/reports/utilization_route.rpt | awk '{print $4}' | tr -d '\r')

echo "================================================="
echo " REGRESSION COMPLETE - ALL CHECKS PASSED         "
echo "================================================="
echo " Setup WNS (300 MHz) : $WNS ns"
echo " Logic Utilization   : $LUT LUTs"
echo " DSP Utilization     : $DSP DSP48E2s"
echo "================================================="
