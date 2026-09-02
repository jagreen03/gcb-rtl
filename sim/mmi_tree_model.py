#!/usr/bin/env python3
# =============================================================================
# mmi_tree_model.py -- GreenCoyote-Bay / ODIN_Bridge
# Task 1 (O1): optical cascade precision and noise model
# =============================================================================
# Numerical model of the GreenCoyote-Bay optical carry-save reduction network:
#   * a SINGLE 8-input cell  -- 8:1 combiner (two 4x1 MMIs -> one 2x1 MMI),
#     photodetector, transimpedance amplifier (TIA), ADC;
#   * a K-STAGE CASCADE of those cells, 8^K compute units -> one result, with
#     an ADC conversion at every stage (per the architecture: each stage
#     converts simultaneously and re-drives modulators for the next stage).
#
# Physical premise (to be confirmed on the Task 3 bench):
#   * Per-channel optical power is LINEAR in the driving digital value.
#   * The MMI tree is a POWER-SUMMING combiner with excess loss only -- ~0.1 dB
#     per stage, per Smolanski & Malka, Micromachines 17(1):31, 2025
#     (doi:10.3390/mi17010031). Optimistic combiner model; a fully
#     mutually-incoherent N:1 combiner would carry ~10*log10(N) dB more.
#   * Each cascade stage RE-NORMALISES its full-scale sum onto the same fixed
#     optical range and the same commercial 12-bit ADC. The per-stage analog
#     SNR is therefore constant; what accumulates is one conversion's worth of
#     shot + quantisation noise per stage, weighted up by that stage's coarser
#     value-per-LSB.
#   * Noise: shot (Poisson electron count), Johnson-Nyquist thermal on R_f,
#     TIA input-referred current noise, and an excess-noise (noise-figure)
#     factor on the non-shot terms.  Modulator nonlinearity, wavelength-
#     dependent MMI imbalance, laser RIN and inter-channel crosstalk are OUT
#     of scope for this baseline.
# =============================================================================

from __future__ import annotations

from dataclasses import dataclass
import numpy as np

# ---- physical constants (SI) ------------------------------------------------
Q_E = 1.602_176_634e-19     # elementary charge [C]
K_B = 1.380_649e-23         # Boltzmann constant [J/K]


# =============================================================================
# Parameters
# =============================================================================

@dataclass
class CellParams:
    # -- combiner tree --------------------------------------------------------
    n_inputs: int = 8                     # 8:1 reduction cell
    stage_il_db: tuple = (0.1, 0.1)       # excess loss of each MMI stage (4x1, 2x1)

    # -- per-channel drive -------------------------------------------------
    input_levels: int = 256              # leaf resolution: 8-bit partial sums
    p_in_max_w: float = 0.1e-3           # optical power for a full-value channel [W]

    # -- photodetector -----------------------------------------------------
    responsivity_a_w: float = 0.9        # O-band InGaAs PD [A/W]
    dark_current_a: float = 5.0e-9       # [A]

    # -- measurement bandwidth ------------------------------------------------
    bandwidth_hz: float = 50.0e6         # noise-equivalent BW ~ commercial eval board

    # -- TIA ---------------------------------------------------------------
    tia_r_f_ohm: float = 2.0e3           # transimpedance gain [V/A]
    tia_in_noise_a_rthz: float = 3.0e-12 # input-referred current-noise density [A/rtHz]
    tia_noise_figure_db: float = 3.0     # excess-noise factor on the non-shot terms
    temperature_k: float = 300.0

    # -- ADC -------------------------------------------------------------------
    adc_bits: int = 12                   # commercial high-speed evaluation board
    adc_fullscale_headroom: float = 0.90 # map a stage's max sum to 90% of ADC FS

    # -- Monte-Carlo -----------------------------------------------------
    seed: int = 20260902

    @property
    def leaf_max(self) -> int:
        """Maximum value of one raw 8-bit leaf input."""
        return self.input_levels - 1


# =============================================================================
# Per-stage scaling
# =============================================================================

@dataclass(frozen=True)
class StageScale:
    """Scaling constants for a cell whose per-channel input tops out at
    `chan_max` (in final-answer units). chan_max = leaf_max * 8**(stage-1)."""
    chan_max: float
    tree_transmission: float
    i_per_chan_unit_a: float     # photocurrent for one final-answer unit on a channel
    adc_lsb_v: float
    value_per_code: float        # final-answer units recovered per ADC code

    @classmethod
    def build(cls, p: CellParams, chan_max: float) -> "StageScale":
        il_total_db = float(np.sum(p.stage_il_db))
        t = 10.0 ** (-il_total_db / 10.0)
        # one final-answer unit on a channel -> this much detector current
        i_per_unit = p.responsivity_a_w * (p.p_in_max_w / chan_max) * t
        # full 8-channel sum -> full-scale detector current -> ADC full scale
        i_full = i_per_unit * (p.n_inputs * chan_max) + p.dark_current_a
        v_full = i_full * p.tia_r_f_ohm
        adc_vfs = v_full / p.adc_fullscale_headroom
        adc_lsb = adc_vfs / (2 ** p.adc_bits)
        value_per_code = adc_lsb / p.tia_r_f_ohm / i_per_unit
        return cls(chan_max, t, i_per_unit, adc_lsb, value_per_code)


# =============================================================================
# Optical + electronic chain
# =============================================================================

def _combiner_output_power(channel_values: np.ndarray, p: CellParams,
                           s: StageScale) -> np.ndarray:
    """Ideal power-summing MMI tree. channel_values: (..., n_inputs) in
    final-answer units. Returns summed optical power [W] with excess loss."""
    p_channels = (channel_values / s.chan_max) * p.p_in_max_w
    return p_channels.sum(axis=-1) * s.tree_transmission


def _detect_and_digitize(p_opt_w: np.ndarray, p: CellParams, s: StageScale,
                         rng: np.random.Generator) -> np.ndarray:
    """Photodetector -> shot/thermal/TIA noise -> TIA -> ADC. Returns ADC codes."""
    B = p.bandwidth_hz
    tau_eff = 1.0 / (2.0 * B)                      # noise-equivalent integration time

    i_mean = p.responsivity_a_w * p_opt_w + p.dark_current_a

    # shot noise: Poisson electron count over tau_eff
    electrons_mean = np.clip(i_mean * tau_eff / Q_E, 0.0, None)
    electrons = rng.poisson(electrons_mean)
    i_shot = electrons * Q_E / tau_eff

    # thermal (Johnson-Nyquist on R_f) + TIA input noise, x excess-noise factor
    excess = 10.0 ** (p.tia_noise_figure_db / 10.0)
    var_thermal = 4.0 * K_B * p.temperature_k * B / p.tia_r_f_ohm
    var_tia = (p.tia_in_noise_a_rthz ** 2) * B
    sigma_nonshot = np.sqrt(excess * (var_thermal + var_tia))
    i_nonshot = rng.normal(0.0, sigma_nonshot, size=i_shot.shape)

    v = (i_shot + i_nonshot) * p.tia_r_f_ohm
    code = np.clip(np.round(v / s.adc_lsb_v), 0, 2 ** p.adc_bits - 1)
    return code.astype(np.int64)


def simulate_cell(inputs_array: np.ndarray, p: CellParams,
                  rng: np.random.Generator, chan_max: float | None = None) -> np.ndarray:
    """Push a batch of 8-input cells through the optical + electronic chain.

    inputs_array : (M, 8) values in final-answer units (already-summed partials).
    chan_max     : max value one channel can carry here; defaults to the leaf
                   8-bit maximum (stage 1). For stage k pass leaf_max * 8**(k-1).
    returns      : (M,) reconstructed sum estimate, in final-answer units.
    """
    if chan_max is None:
        chan_max = float(p.leaf_max)
    s = StageScale.build(p, chan_max)
    p_opt = _combiner_output_power(inputs_array, p, s)
    code = _detect_and_digitize(p_opt, p, s, rng)
    return code * s.value_per_code


# =============================================================================
# Cascade
# =============================================================================

def simulate_cascade(total_inputs: int, depth: int, p: CellParams,
                     rng: np.random.Generator, n_vectors: int) -> dict:
    """Feed `total_inputs` (= 8**depth) random 8-bit values through `depth`
    cascaded 8:1 optical reduction stages and compare the recovered sum to the
    exact digital sum. Returns error statistics over `n_vectors` trials."""
    assert total_inputs == p.n_inputs ** depth, "total_inputs must equal 8**depth"

    leaves = rng.integers(0, p.input_levels, size=(n_vectors, total_inputs), dtype=np.int64)
    true_sum = leaves.sum(axis=1).astype(np.float64)          # exact digital sum

    values = leaves.astype(np.float64)                        # (n_vectors, cur_width)
    cur_width = total_inputs
    for stage in range(1, depth + 1):
        n_cells = cur_width // p.n_inputs
        chan_max = float(p.leaf_max) * (p.n_inputs ** (stage - 1))
        batch = values.reshape(n_vectors * n_cells, p.n_inputs)
        out = simulate_cell(batch, p, rng, chan_max=chan_max)
        values = out.reshape(n_vectors, n_cells)
        cur_width = n_cells

    est = values[:, 0]                                        # (n_vectors,)
    err = est - true_sum

    fs = total_inputs * p.leaf_max                            # full-scale digital sum
    max_abs = float(np.max(np.abs(err)))
    rms = float(np.sqrt(np.mean(err ** 2)))
    k = int(np.argmax(np.abs(err)))
    return {
        "depth": depth,
        "total_inputs": total_inputs,
        "full_scale_sum": fs,
        "n_vectors": n_vectors,
        "max_abs_error_lsb": max_abs,
        "rms_error_lsb": rms,
        "max_error_frac_fs": max_abs / fs,
        "eff_bits_peak": float(np.log2(fs / max_abs)) if max_abs > 0 else float("inf"),
        "eff_bits_rms": float(np.log2(fs / (rms * np.sqrt(12.0)))) if rms > 0 else float("inf"),
        "worst_case": (float(true_sum[k]), float(est[k]), float(err[k])),
    }


# =============================================================================
# __main__
# =============================================================================

def main() -> None:
    p = CellParams()
    rng = np.random.default_rng(p.seed)

    print("=" * 74)
    print(" GreenCoyote-Bay -- cascaded optical reduction: precision vs. depth (O1)")
    print("=" * 74)
    print(f"  cell            : 8:1 (4x1 -> 2x1), excess loss {sum(p.stage_il_db):.2f} dB")
    print(f"  per-channel      : {p.input_levels}-level leaves, {p.p_in_max_w*1e3:.2f} mW full")
    print(f"  detector / TIA   : R={p.responsivity_a_w:.2f} A/W, R_f={p.tia_r_f_ohm/1e3:.1f} kOhm, "
          f"i_n={p.tia_in_noise_a_rthz*1e12:.1f} pA/rtHz, NF={p.tia_noise_figure_db:.1f} dB")
    print(f"  ADC              : {p.adc_bits}-bit, re-normalised per stage, "
          f"{p.bandwidth_hz/1e6:.0f} MHz BW, T={p.temperature_k:.0f} K")
    print("-" * 74)
    header = (f"  {'K':>2}  {'units':>7}  {'full-scale sum':>14}  "
             f"{'MAX DEV (LSB)':>13}  {'RMS (LSB)':>10}  {'eff.bits(pk)':>12}  {'eff.bits(rms)':>13}")
    print(header)
    print("  " + "-" * (len(header) - 2))

    # K = 1 reference (single cell) then the requested cascade depths
    plan = [(1, 20000), (2, 6000), (3, 3000), (4, 1200)]
    rows = []
    for depth, n_vec in plan:
        n = p.n_inputs ** depth
        r = simulate_cascade(n, depth, p, rng, n_vec)
        rows.append(r)
        print(f"  {depth:>2}  {n:>7}  {r['full_scale_sum']:>14}  "
              f"{r['max_abs_error_lsb']:>13.3f}  {r['rms_error_lsb']:>10.3f}  "
              f"{r['eff_bits_peak']:>12.2f}  {r['eff_bits_rms']:>13.2f}")

    print("  " + "-" * (len(header) - 2))
    print()
    print("  worst-case single trial per depth (true sum / estimate / error in LSB):")
    for r in rows:
        t, e, d = r["worst_case"]
        print(f"    K={r['depth']}:  {t:>12.0f}  /  {e:>13.2f}  /  {d:>+9.3f}")
    print()

    # locate the 8-bit crossing
    broke = [r for r in rows if r["eff_bits_peak"] < 8.0]
    if broke:
        first = min(broke, key=lambda r: r["depth"])
        print(f"  >> INT8-equivalent (8-bit peak) floor BROKEN at K = {first['depth']} "
              f"({first['total_inputs']} units): peak resolution "
              f"{first['eff_bits_peak']:.2f} bits.")
    else:
        worst = min(rows, key=lambda r: r["eff_bits_peak"])
        print(f"  >> INT8-equivalent (8-bit peak) floor HOLDS through K = {rows[-1]['depth']} "
              f"({rows[-1]['total_inputs']} units).")
        print(f"     Tightest point: K={worst['depth']} at "
              f"{worst['eff_bits_peak']:.2f} bits peak "
              f"({worst['eff_bits_peak'] - 8.0:+.2f} bits of margin).")
    print("=" * 74)


if __name__ == "__main__":
    main()
