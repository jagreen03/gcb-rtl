#!/usr/bin/env python3
"""
ss_energy.py  --  per-net transition counts from sim_out/ss_energy.vcd (one
256 ns single-slope observation window = 64 conversions) -> energy per MAC for
the readout DIGITAL back-end, with ASAP7 7.5T representative switched caps.

ASAP7 caps (Clark et al., "ASAP7: A 7-nm FinFET predictive PDK",
Microelectronics Journal 2016; OpenROAD ASAP7 char.):
    C_ff   = 0.80 fF   per D-flop bit toggle  (clk + master/slave + Q + local net)
    C_gate = 0.30 fF   per combinational net bit toggle
    C_dist = 6.0  fF   per Gray-distribution bit toggle (broadcast to 4 phase
             banks + 16-ch clusters WITH local re-buffering; a raw fan-out-64
             net would be ~15 fF -> a 2.5x pessimistic bound is also printed)
    VDD    = 0.70 V    ASAP7 nominal logic rail
E per bit toggle = 0.5 * C * VDD^2 .
"""
import sys

C_FF, C_GATE, C_DIST, VDD = 0.80e-15, 0.30e-15, 6.0e-15, 0.70
K_TOTAL, NCH = 8192, 64
CAL_MODELLED = 16        # tb feeds 16 calib convs; window has NCH -> scale x(NCH/16)

VCD = sys.argv[1] if len(sys.argv) > 1 else "sim_out/ss_energy.vcd"


def parse(path):
    ids, counts, prev, scope = {}, {}, {}, []
    started = False
    for ln in open(path):
        s = ln.strip()
        if s.startswith("$scope"):
            scope.append(s.split()[2])
        elif s.startswith("$upscope"):
            scope and scope.pop()
        elif s.startswith("$var"):
            p = s.split()
            w, vid, nm = int(p[2]), p[3], p[4]
            ids[vid] = (".".join(scope + [nm]), w)
            counts[vid] = 0; prev[vid] = None
        elif s.startswith("#"):
            started = True
        elif started and s:
            if s[0] == "b":
                mv = s.split()
                if len(mv) != 2:
                    continue
                val, vid = mv[0][1:], mv[1]
            elif s[0] in "01xzXZ" and len(s) >= 2:
                val, vid = s[0], s[1:]
            else:
                continue
            if vid in counts:
                if prev[vid] is not None and val != prev[vid]:
                    counts[vid] += 1
                prev[vid] = val
    return ids, counts


def main():
    ids, counts = parse(VCD)
    # collapse to (name -> change_count), keep the max across duplicate/aliased ids
    by_name = {}
    for vid, c in counts.items():
        nm, w = ids[vid]
        by_name.setdefault(nm, [w, 0])
        by_name[nm][1] = max(by_name[nm][1], c)

    ff = gate = dist = 0.0
    rows = []
    seen_gray_bus = False
    seen = set()
    for nm, (w, c) in sorted(by_name.items()):
        low = nm.lower()
        if c == 0:
            continue
        # exclusions: clocks, TB loop vars, resets, TB control stimulus
        if ("clk_ph" in low or low.endswith(".clk") or ".per" in low
                or low.endswith(".t") or low.endswith(".i") or low.endswith(".j")
                or "rst_n" in low or "prev_gray" in low or "cnt_en" in low
                or "rd_clear" in low or low.endswith(".rd_ch") or low.endswith(".cal_iv")):
            continue
        # dedup top-level port alias vs the u_tdc/u_cal internal net of same leaf
        leaf = low.rsplit(".", 1)[-1]
        if low.startswith("tb_ss_energy.") and ".u_" not in low and leaf in seen:
            continue
        seen.add(leaf)

        # ---- structural bit-toggle models (all TDC nets change ~1 bit/event) --
        if low.endswith("u_tdc.gray_lat"):
            bt = c; ff += bt; rows.append((c, w, "ff", nm, bt)); continue
        if ("gray_cnt" in low or low.endswith(".gray_o")):
            if seen_gray_bus:
                continue
            seen_gray_bus = True
            bt = c; dist += bt; rows.append((c, w, "dist", nm, bt)); continue
        if low.endswith("u_tdc.bin_cnt"):
            bt = c * 2; ff += bt; rows.append((c, w, "ff", nm, bt)); continue

        # ---- generic : datapath (u_cal acc/mul) moves many bits/event,
        #      everything else moves ~1 bit/event -----------------------------
        is_dp = ".u_cal." in low and any(k in leaf for k in
                                         ("acc1", "acc2", "x_hat", "t3", "acc3"))
        kind = "ff" if any(k in leaf for k in (
            "fs_q", "fired", "cap_gray", "cap_therm", "acc1", "acc2", "code1",
            "code2", "c1_1", "c0_1", "c0_2", "v1", "v2", "x_hat", "out_valid",
            "fired_mask")) else "gate"
        bt = (c * max(1.0, w / 2.0)) if is_dp else float(c)
        if kind == "ff":
            ff += bt
        else:
            gate += bt
        rows.append((c, w, kind, nm, bt))

    # scale the calib-pipe contribution 16 -> 64 conversions
    scale = NCH / CAL_MODELLED
    cal_bt = sum(bt for (c, w, k, nm, bt) in rows if ".u_cal." in nm.lower())
    ff   += cal_bt * (scale - 1) * 0.6
    gate += cal_bt * (scale - 1) * 0.4

    def E(bt, C):
        return bt * 0.5 * C * VDD ** 2

    # the two 48x15 Horner multipliers are inlined (function, no wire in VCD).
    # 48x15 array ~ 720 PP AND + ~700 adder cells; ~35% activity -> ~500
    # gate-toggles / multiply.  2 per conversion, NCH conversions.
    mult_bt = NCH * 2 * 500
    gate += mult_bt

    e_win = E(ff, C_FF) + E(gate, C_GATE) + E(dist, C_DIST)
    e_win_pess = E(ff, C_FF) + E(gate, C_GATE) + E(dist, C_DIST * 2.5)
    e_conv, e_mac = e_win / NCH, e_win / NCH / K_TOTAL
    e_mac_pess = e_win_pess / NCH / K_TOTAL

    print("single-slope readout DIGITAL back-end -- one 256 ns window (64 conv):")
    print(f"  flop bit-toggles : {ff:10.0f}  x {C_FF*1e15:.2f} fF")
    print(f"  gate bit-toggles : {gate:10.0f}  x {C_GATE*1e15:.2f} fF")
    print(f"  Gray-dist toggles: {dist:10.0f}  x {C_DIST*1e15:.1f} fF")
    print(f"  VDD = {VDD} V ;  E/toggle = 0.5*C*VDD^2")
    print()
    print(f"  E(window)        = {e_win*1e12:8.3f} pJ")
    print(f"  E / conversion   = {e_conv*1e12:8.4f} pJ")
    print(f"  E / MAC          = {e_mac*1e15:8.4f} fJ/MAC   (K_total={K_TOTAL})")
    print(f"  E / MAC (2.5x Gray-dist pessimistic) = {e_mac_pess*1e15:.4f} fJ/MAC")
    print()
    print("  top nets by weighted bit-toggles:")
    for c, w, k, nm, bt in sorted(rows, key=lambda r: -r[4])[:12]:
        print(f"    {bt:9.0f}  ({c:6d} chg, w={w:<3d} {k:4s})  {nm}")


if __name__ == "__main__":
    main()
