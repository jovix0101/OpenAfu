# Body composition model

The phone app does **not** compute body fat on the device. `ICAlgorithmManager.calc()` is a
stub that returns its argument unchanged; the app uploads
`{indicator:"weight", weightKg, weightLb, algType:"41", imps:"[500,514]"}` and the server
answers with the twelve metrics. So the numbers had to be recovered empirically.

> Every figure in this file is **synthetic demo data** (a 175 cm / 42 y / male profile).
> Replace with your own measurements when re-anchoring.

## The model

All twelve metrics are linear in a single free variable, the fat-free mass:

```
Zavg = mean(impedance values in the 0xD6 frame)
FFM  = K * H^2 / Zavg          K = 0.9788, H in cm
fatKg = W - FFM
```

Then, as fractions of FFM (matched the vendor app's official output exactly):

| metric | coefficient |
|---|---|
| body water | 0.63183 × FFM |
| protein | 0.31068 × FFM |
| muscle | 0.95090 × FFM |
| skeletal muscle | 0.43868 × FFM |
| BMR | 370 + 21.6 × FFM (Katch-McArdle) |

Percentages of body weight: `water/W*100`, `protein/W*100`, `muscle/W*100`,
`skelMuscle/W*100`, `fatKg/W*100`. And `BMI = W / (H/100)^2`.

Worked example — 78.40 kg, impedance 500/514 Ω, H = 175:

```
Zavg   507.0            FFM     59.1 kg        fat      19.3 kg (24.6 %)
water  37.4 kg (47.6 %) protein 18.4 kg (23.4 %)  muscle  56.2 kg (71.7 %)
skel   25.9 kg (33.1 %) BMR     1647 kcal      BMI      25.6
```

Mifflin-St Jeor gives a materially different BMR for the same input and does **not** fit —
Katch-McArdle is the formula in use.

## Calibration anchors

Solving `Z_implied = K * H^2 / FFM` for each known (weight, fat%) pair, on a demo profile:

| source | weight | fat% | measured Z | implied Z |
|---|---|---|---|---|
| app sync #1 | 79.00 | 24.1 | 500 | 499.9 |
| app sync #2 | 78.60 | 25.5 | 512 | 511.9 |
| scale screen | 78.80 | 24.7 | 505 | 505.2 |

Agreement within ~2 %, so `K` is determined to roughly that precision.

## How to re-anchor for another person or a different unit

1. Weigh once **with the tool connected** and keep the `0xD6` frame (gives `Zavg`).
2. Weigh once **with the vendor app**, note the displayed fat%.
3. `K = fat%-derived FFM * Zavg / H^2`, with `FFM = W * (1 - fat%)`.
4. Repeat at 2–3 different body states and average.

## Caveats

- `K` was fitted on **one person**. It absorbs age/sex/height constants that a real
  algorithm would apply separately — re-anchor before trusting it elsewhere.
- A wrong height skews FFM quadratically.
- If `adcs = [0, 0]` there is no impedance at all; emit no metrics and report
  "no measurement" rather than zeros.
- The two impedance values are left/right foot and normally differ by a few percent. Their
  mean is used. With a single full anchor, a single-value model fits equally well — the
  choice is unverified.

## Verification snippet

```bash
python3 -c "
H=175.0; K=0.9788
W, Z1, Z2 = 78.40, 500, 514
ffm = K*H*H/((Z1+Z2)/2); fat = W-ffm
print(f'fat={fat/W*100:.1f}% FFM={ffm:.1f} BMR={370+21.6*ffm:.0f}')"
```

## Derived indices (computed, not measured)

All of these come from the numbers above — label them as estimates in any UI, because
only weight and the two impedances actually leave the scale.

| Index | Formula | Note |
|---|---|---|
| FFMI | `ffm / H²` | normalised variant: `+ 6.1 × (1.8 − H_m)` |
| FMI | `fatKg / H²` | |
| BMR | `370 + 21.6 × ffm` | Katch-McArdle — needs FFM, which is why it beats weight-only formulas |
| TDEE | `BMR × 1.2 / 1.375 / 1.55` | sedentary / light / moderate. A pure assumption about activity — never present it as measured |
| target weight | `ffm / (1 − targetFatPct)` | target fat % defaults to 20% |
| muscle:fat | `muscleKg / fatKg` | > 4 is usually "lean" |

Sanity check for the sedentary default: a 78 kg / 24% male lands near 1 650 kcal BMR and
~1 980 kcal TDEE; a scale that claims to *measure* TDEE is lying, it only knows weight and
impedance.
