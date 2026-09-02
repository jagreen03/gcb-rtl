#!/usr/bin/env python3
# =============================================================================
# mmi_tree_model.py -- GreenCoyote-Bay / ODIN_Bridge
# Task 1 (O1): optical cascade precision and noise model -- SINGLE CELL
# =============================================================================
# First-cut numerical model of ONE 8-input optical carry-save reduction cell:
# an 8:1 combiner tree (two 4x1 MMIs feeding one 2x1 MMI) followed by a
# photodetector, transimpedance amplifier (TIA) and ADC. It establishes the
# single-cell error floor -- the reference point before any cascading.
#
# Physical premise (to be confirmed on the Task 3 bench):
#   * Each compute unit drives an electro-optic modulator; the per-channel
#     optical power is LINEAR in the unit's digital partial-sum value.
#   * The MMI tree is treated as a POWER-SUMMING combiner with only excess
#     (insertion) loss -- ~0.1 dB per stage, per the cascaded-MMI silicon
#     demonstration of Smolanski & Malka, Micromachines 17(1):31, 2025
#     (doi:10.3390/mi17010031). This is the optimistic combiner model; a
#     fully mutually-incoherent N:1 combiner would carry an additional
#     ~10*log10(N) dB. Resolving which regime applies is a Phase I goal.
#   * The detector sees the summed optical power. Shot noise (Poisson) and
#     Johnson-Nyquist thermal noise are modelled; the TIA adds its own
#     input-referred current noise and an excess-noise (noise-figure) factor.
#   * The ADC rounds to n bits over a fixed full-scale voltage, with clipping.
#
# Everything here is a Gaussian/Poisson small-signal model. Modulator
# nonlinearity, wavelength-dependent MMI imbalance, laser RIN and inter-channel
# crosstalk are deliberately OUT of scope for this baseline.
# =============================================================================

from __future__ import annotations

from dataclasses import dataclass, field
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
    n_inputs: int = 8               # 8:1 reduction cell
    stage_il_db: tuple = (0.1, 0.1) # excess loss of each MMI stage: 4x1, then 2x1
    #   (Smolanski & Malka 2025 report ~0.1 dB for the cascaded 4-input MMI)

    # -- per-channel drive -------------------------------------------------
    input_levels: int = 256        # digital partial-sum resolution per channel (8-bit)
    p_in_max_w: float = 0.1e-3     # optical power per channel at full digital value [W]
    #   100 uW/channel -> ~0.69 mA detector current at full 8-channel sum,
    #   which a kOhm-range TIA can hold without saturating.

    # -- photodetector -----------------------------------------------------
    responsivity_a_w: float = 0.9  # O-band InGaAs PD [A/W]
    dark_current_a: float = 5.0e-9 # [A]

    # -- measurement bandwidth ------------------------------------------------
    bandwidth_hz: float = 50.0e6   # noise-equivalent bandwidth ~ commercial
    #   >=12-bit, tens-of-MS/s eval board

    # -- TIA ---------------------------------------------------------------
    tia_r_f_ohm: float = 2.0e3     # transimpedance gain [V/A] (V_fs ~1.5 V at full sum)
    tia_in_noise_a_rthz: float = 3.0e-12   # input-referred current-noise density [A/sqrt(Hz)]
    tia_noise_figure_db: float = 3.0       # excess-noise factor on the non-shot terms
    temperature_k: float = 300.0

    # -- ADC -------------------------------------------------------------------
    adc_bits: int = 12             # commercial high-speed evaluation board
    adc_fullscale_headroom: float = 0.90   # map the max sum to 90 % of ADC full scale

    # -- sweep / Monte-Carlo -----------------------------------------------
    sweep_levels: int = 64         # distinct sum-magnitude points across the range
    trials_per_level: int = 400    # noise realisations per point
    seed: int = 20260902

    # -- derived (filled in post-init) --------------------------------------
    tree_transmission: float = field(init=False)
    full_scale_sum: int = field(init=False)          # max reconstructable digital sum
    i_per_input_lsb_a: float = field(init=False)     # photocurrent for one input LSB
    adc_vfs_v: float = field(init=False)
    adc_lsb_v: float = field(init=False)

    def __post_init__(self) -> None:
        il_total_db = float(np.sum(self.stage_il_db))
        self.tree_transmission = 10.0 ** (-il_total_db / 10.0)
        self.full_scale_sum = self.n_inputs * (self.input_levels - 1)

        # photocurrent produced by one channel raised by one digital LSB
        p_per_lsb = (self.p_in_max_w / (self.input_levels - 1)) * self.tree_transmission
        self.i_per_input_lsb_a = self.responsivity_a_w * p_per_lsb

        i_at_full_sum = self.i_per_input_lsb_a * self.full_scale_sum + self.dark_current_a
        v_at_full_sum = i_at_full_sum * self.tia_r_f_ohm
        self.adc_vfs_v = v_at_full_sum / self.adc_fullscale_headroom
        self.adc_lsb_v = self.adc_vfs_v / (2 ** self.adc_bits)


# =============================================================================
# Model
# =============================================================================

def combiner_output_power(channel_digital: np.ndarray, p: CellParams) -> np.ndarray:
    """Ideal power-summing MMI tree. channel_digital: (..., n_inputs) integer array.
    Returns summed optical power at the tree output [W] with excess loss applied."""
    frac = channel_digital / (p.input_levels - 1)                 # 0..1 per channel
    p_channels = frac * p.p_in_max_w                              # [W] per channel
    return p_channels.sum(axis=-1) * p.tree_transmission          # [W] at output


def detect_and_digitize(p_opt_w: np.ndarray, p: CellParams,
                        rng: np.random.Generator) -> np.ndarray:
    """Photodetector -> noise -> TIA -> ADC. Returns the ADC code array (ints)."""
    B = p.bandwidth_hz
    tau_eff = 1.0 / (2.0 * B)          # noise-equivalent integration time

    i_mean = p.responsivity_a_w * p_opt_w + p.dark_current_a     # [A] mean photocurrent

    # --- shot noise: Poisson electron count over tau_eff -------------------
    electrons_mean = np.clip(i_mean * tau_eff / Q_E, 0.0, None)
    electrons = rng.poisson(electrons_mean)
    i_shot = electrons * Q_E / tau_eff                            # [A], shot-limited current

    # --- thermal (Johnson-Nyquist on R_f) + TIA input noise, x noise figure
    excess = 10.0 ** (p.tia_noise_figure_db / 10.0)
    var_thermal = 4.0 * K_B * p.temperature_k * B / p.tia_r_f_ohm  # [A^2]
    var_tia = (p.tia_in_noise_a_rthz ** 2) * B                     # [A^2]
    sigma_nonshot = np.sqrt(excess * (var_thermal + var_tia))
    i_nonshot = rng.normal(0.0, sigma_nonshot, size=i_shot.shape)

    i_total = i_shot + i_nonshot

    # --- TIA transimpedance -> ADC ---------------------------------------
    v = i_total * p.tia_r_f_ohm
    code = np.round(v / p.adc_lsb_v)
    code = np.clip(code, 0, 2 ** p.adc_bits - 1)
    return code.astype(np.int64)


def reconstruct_sum(adc_code: np.ndarray, p: CellParams) -> np.ndarray:
    """Invert the nominal chain gain to recover an estimate of the digital sum."""
    v = adc_code * p.adc_lsb_v
    i = v / p.tia_r_f_ohm - p.dark_current_a
    return i / p.i_per_input_lsb_a          # estimate in units of input LSBs


def noise_budget(p: CellParams) -> dict:
    """Per-term current-noise sigma at full scale, in input-LSB units."""
    B = p.bandwidth_hz
    i_full = p.i_per_input_lsb_a * p.full_scale_sum + p.dark_current_a
    excess = 10.0 ** (p.tia_noise_figure_db / 10.0)
    sig_shot = np.sqrt(2.0 * Q_E * i_full * B)
    sig_thermal = np.sqrt(excess * 4.0 * K_B * p.temperature_k * B / p.tia_r_f_ohm)
    sig_tia = np.sqrt(excess * (p.tia_in_noise_a_rthz ** 2) * B)
    sig_quant = p.adc_lsb_v / p.tia_r_f_ohm / np.sqrt(12.0)
    to_lsb = 1.0 / p.i_per_input_lsb_a
    return {
        "shot (full scale)": sig_shot * to_lsb,
        "thermal R_f":        sig_thermal * to_lsb,
        "TIA input":          sig_tia * to_lsb,
        "ADC quantization":   sig_quant * to_lsb,
    }


# =============================================================================
# Sweep
# =============================================================================

def run_sweep(p: CellParams) -> dict:
    rng = np.random.default_rng(p.seed)
    max_per_ch = p.input_levels - 1

    # sum-magnitude sweep: from a low non-zero level up to all channels maxed
    target_sums = np.linspace(p.n_inputs, p.full_scale_sum, p.sweep_levels)

    err_abs_max = 0.0
    err_sq_accum = 0.0
    n_samples = 0
    worst = None

    for target in target_sums:
        # distribute 'target' across n_inputs channels, quantised to integers,
        # then jitter the split trial-to-trial so we exercise many vectors
        base = np.full(p.n_inputs, target / p.n_inputs)
        for _ in range(p.trials_per_level):
            jitter = rng.uniform(-0.15, 0.15, size=p.n_inputs) * base
            chan = np.clip(np.round(base + jitter), 0, max_per_ch).astype(np.int64)
            true_sum = int(chan.sum())

            p_opt = combiner_output_power(chan[None, :], p)          # shape (1,)
            code = detect_and_digitize(p_opt, p, rng)
            est = reconstruct_sum(code, p)[0]

            err = est - true_sum                                     # input-LSB units
            err_sq_accum += err * err
            n_samples += 1
            if abs(err) > err_abs_max:
                err_abs_max = abs(err)
                worst = (true_sum, float(est), float(err))

    err_rms = float(np.sqrt(err_sq_accum / n_samples))
    fs = p.full_scale_sum
    return {
        "n_samples": n_samples,
        "max_abs_error_lsb": err_abs_max,
        "rms_error_lsb": err_rms,
        "max_error_frac_fs": err_abs_max / fs,
        "rms_error_frac_fs": err_rms / fs,
        "effective_bits_peak": float(np.log2(fs / err_abs_max)) if err_abs_max > 0 else float("inf"),
        "effective_bits_rms": float(np.log2(fs / (err_rms * np.sqrt(12.0)))) if err_rms > 0 else float("inf"),
        "worst_case": worst,
    }


# =============================================================================
# __main__
# =============================================================================

def main() -> None:
    p = CellParams()

    print("=" * 70)
    print(" GreenCoyote-Bay -- single 8-input optical reduction cell")
    print(" Task 1 (O1) baseline error-floor model")
    print("=" * 70)
    print(f"  combiner tree        : {p.n_inputs}:1  (4x1 -> 2x1),  "
          f"excess loss {sum(p.stage_il_db):.2f} dB  "
          f"(T = {p.tree_transmission:.4f})")
    print(f"  per-channel drive    : {p.input_levels}-level, {p.p_in_max_w*1e3:.2f} mW full")
    print(f"  photodetector        : R = {p.responsivity_a_w:.2f} A/W, "
          f"I_dark = {p.dark_current_a*1e9:.1f} nA")
    print(f"  bandwidth            : {p.bandwidth_hz/1e6:.1f} MHz")
    print(f"  TIA                  : R_f = {p.tia_r_f_ohm/1e3:.1f} kOhm, "
          f"i_n = {p.tia_in_noise_a_rthz*1e12:.1f} pA/rtHz, "
          f"NF = {p.tia_noise_figure_db:.1f} dB, T = {p.temperature_k:.0f} K")
    print(f"  ADC                  : {p.adc_bits}-bit, "
          f"V_fs = {p.adc_vfs_v*1e3:.1f} mV, LSB = {p.adc_lsb_v*1e6:.2f} uV")
    print(f"  full-scale digital sum : {p.full_scale_sum}  "
          f"(= {p.n_inputs} x {p.input_levels-1})")
    print("-" * 70)

    print("  noise budget  (current-noise sigma, in input-LSB units):")
    for name, val in noise_budget(p).items():
        print(f"    {name:<20s} : {val:8.4f} LSB")
    print("-" * 70)

    res = run_sweep(p)
    tsum, est, err = res["worst_case"]
    print(f"  Monte-Carlo            : {res['n_samples']} input vectors "
          f"({p.sweep_levels} levels x {p.trials_per_level} trials)")
    print()
    print(f"  MAX DEVIATION  from ideal digital sum : "
          f"{res['max_abs_error_lsb']:.3f} input-LSB  "
          f"({res['max_error_frac_fs']*1e6:.1f} ppm of full scale)")
    print(f"  RMS deviation                         : "
          f"{res['rms_error_lsb']:.3f} input-LSB  "
          f"({res['rms_error_frac_fs']*1e6:.1f} ppm of full scale)")
    print(f"  worst case: true sum {tsum}, estimate {est:.2f}  (err {err:+.3f} LSB)")
    print()
    print(f"  single-cell resolution (peak error)   : "
          f"{res['effective_bits_peak']:.2f} bits")
    print(f"  single-cell resolution (RMS / ENOB-like): "
          f"{res['effective_bits_rms']:.2f} bits")
    print("=" * 70)
    print(" INT8-equivalent (8-bit) reduction needs the peak-error resolution")
    print(" to stay >= 8 bits. This is the pre-cascade floor; each added stage")
    print(" adds one conversion's worth of shot + quantisation noise.")
    print("=" * 70)


if __name__ == "__main__":
    main()
