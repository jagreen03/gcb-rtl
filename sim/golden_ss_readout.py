#!/usr/bin/env python3
"""
golden_ss_readout.py  --  fixed-point golden model for the GCB single-slope
readout digital back-end (gcb-rtl/rtl/greencoyote_ss_calib.sv +
greencoyote_ss_tdc.sv).

Ports the two behavioural functions of ss_readout_mc.py:

    convert()    ->  fx_convert(x)          : ideal single-slope quantiser,
                                              x in [0,1) of FS  ->  14-bit code
                                              {coarse[13:2], phase[1:0]}
    calibrate()  ->  fx_fit_3pt(...)        : 3-point (quadratic) fit of the
                     + fx_calib(code, C)      per-channel transfer, then
                                              x_hat = C2*u^2 + C1*u + C0
                                              evaluated by Horner in fixed point.

FIXED-POINT CONTRACT  (must match greencoyote_ss_calib.sv exactly)
-----------------------------------------------------------------
  code    : 14-bit unsigned, 0 .. 16383        (CW = 14)
  u       : code as a Q0.14 fraction, u = code / 2**14     (implicit; RTL uses
            the raw integer `code` and shifts by CW)
  C0,C1,C2: signed 32-bit, format Q4.28   (value * 2**28, range +-8)
  Horner, signed 48-bit accumulator ACC (Q4.28):
      acc = C2
      acc = sra(acc * code, 14) + C1
      acc = sra(acc * code, 14) + C0
  output x_hat : unsigned Q2.16, 18-bit (0 .. 0x3FFFF):
      t     = sra(acc + (1 << 11), 12)         ; round Q4.28 -> Q4.16
      x_hat = 0        if t < 0
              0x3FFFF  if t > 0x3FFFF
              t        otherwise
  sra(v,n) = arithmetic right shift (Python `v >> n` already floors to -inf).
"""
import argparse
import os
import random

CW        = 14
CODE_MAX  = (1 << CW) - 1            # 16383
QC        = 28                       # coefficient fractional bits (Q4.28)
COEF_BITS = 32
COEF_MIN  = -(1 << (COEF_BITS - 1))
COEF_MAX  =  (1 << (COEF_BITS - 1)) - 1
ACC_BITS  = 48
XHAT_BITS = 18
XHAT_MAX  = (1 << XHAT_BITS) - 1     # 0x3FFFF

N_COARSE = 1 << 12
N_PHASE  = 1 << 2


def fx_convert(x):
    """x in [0,1) of full scale -> 14-bit code (coarse<<2 | phase).

    Ideal noise-free linear-ramp path of ss_readout_mc.one_ramp: a 14-bit
    uniform quantiser, truncate (ramp compared with '>' == searchsorted
    side='right' - 1)."""
    q = int(x * (1 << CW))
    return 0 if q < 0 else CODE_MAX if q > CODE_MAX else q


def to_q428(v):
    q = int(round(v * (1 << QC)))
    return COEF_MIN if q < COEF_MIN else COEF_MAX if q > COEF_MAX else q


def fx_fit_3pt(cs, xs):
    """3-point quadratic fit  xs ~= a*cs^2 + b*cs + c  (cs raw codes),
    returned as (C2,C1,C0) in Q4.28 on the normalised axis u = code/2^14:
        x_hat = a*code^2 + b*code + c = C2*u^2 + C1*u + C0
    -> C2 = a*2^28 , C1 = b*2^14 , C0 = c
    The solve is a firmware/host float operation; only Horner is in RTL."""
    c0, c1, c2 = cs
    x0, x1, x2 = xs
    d = (c0 - c1) * (c0 - c2) * (c1 - c2)
    a = (x0 * (c1 - c2) - x1 * (c0 - c2) + x2 * (c0 - c1)) / d
    b = (-x0 * (c1 * c1 - c2 * c2) + x1 * (c0 * c0 - c2 * c2)
         - x2 * (c0 * c0 - c1 * c1)) / d
    c = (x0 * c1 * c2 * (c1 - c2) - x1 * c0 * c2 * (c0 - c2)
         + x2 * c0 * c1 * (c0 - c1)) / d
    return to_q428(a * (1 << 28)), to_q428(b * (1 << 14)), to_q428(c)


def _sext(v, bits):
    v &= (1 << bits) - 1
    return v - (1 << bits) if v & (1 << (bits - 1)) else v


def fx_calib(code, C2, C1, C0):
    """Fixed-point Horner -- BIT-EXACT reference for greencoyote_ss_calib.sv."""
    code &= CODE_MAX
    acc = _sext(C2, COEF_BITS)
    acc = (acc * code) >> CW
    acc = _sext(acc + _sext(C1, COEF_BITS), ACC_BITS)
    acc = (acc * code) >> CW
    acc = _sext(acc + _sext(C0, COEF_BITS), ACC_BITS)
    t = (acc + (1 << 11)) >> 12
    return 0 if t < 0 else XHAT_MAX if t > XHAT_MAX else t


# ---------------------------------------------------------------------------
def gen_vectors(n, seed, path):
    rng = random.Random(seed)
    rows = []
    for _ in range(int(n * 0.4)):                       # realistic fitted coeffs
        span = rng.uniform(0.30, 0.55)
        c_lo = rng.uniform(20, 400)
        c_hi = c_lo + rng.uniform(6000, 15000)
        bow  = rng.uniform(-0.02, 0.02) * span
        cs = (c_lo, 0.5 * (c_lo + c_hi), c_hi)

        def curve(cc, _lo=c_lo, _hi=c_hi, _s=span, _b=bow):
            u = (cc - _lo) / (_hi - _lo)
            return _s * u + 4 * _b * u * (1 - u)

        xs = tuple(curve(cc) for cc in cs)
        C2, C1, C0 = fx_fit_3pt(cs, xs)
        for _ in range(6):
            rows.append((rng.randint(0, CODE_MAX), C2, C1, C0))
    while len(rows) < int(n * 0.8):                     # uniform-random coeffs
        rows.append((rng.randint(0, CODE_MAX),
                     rng.randint(-(1 << 30), (1 << 30)),
                     rng.randint(-(1 << 30), (1 << 30)),
                     rng.randint(COEF_MIN, COEF_MAX)))
    ec = [0, 1, CODE_MAX - 1, CODE_MAX, 1 << 13, 1 << 12]
    ek = [0, 1, -1, COEF_MAX, COEF_MIN, 1 << QC, -(1 << QC), 1 << 27, -(1 << 27)]
    while len(rows) < n:                                # edge cases
        code = rng.choice(ec) if rng.random() < 0.5 else rng.randint(0, CODE_MAX)
        rows.append((code, rng.choice(ek), rng.choice(ek), rng.choice(ek)))
    rng.shuffle(rows)
    rows = rows[:n]
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(f"# code C2hex C1hex C0hex xhat_expected_hex   "
                f"n={n} seed={seed} CW={CW} QC={QC} XHAT_BITS={XHAT_BITS}\n")
        for code, C2, C1, C0 in rows:
            xh = fx_calib(code, C2, C1, C0)
            f.write(f"{code:5d} {C2 & 0xFFFFFFFF:08x} {C1 & 0xFFFFFFFF:08x} "
                    f"{C0 & 0xFFFFFFFF:08x} {xh:05x}\n")
    return len(rows)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=10000)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--out", default="sim_out/ss_calib_vectors.txt")
    a = ap.parse_args()
    print(f"wrote {gen_vectors(a.n, a.seed, a.out)} vectors -> {a.out}")
