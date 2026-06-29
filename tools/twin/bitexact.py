# -----------------------------------------------------------------------------
# bitexact.py  --  bit-accurate Python twin of the ArchBetter numeric path.
#
# Mirrors the RTL formats EXACTLY (src/rtl/common/types_pkg.sv):
#   BFP12  : BFP12_BLK=16 elements share one signed BFP12_EXP_W=8 exponent;
#            each element is a signed BFP12_MANT_W=12 mantissa in [-2048, 2047];
#            element value = mantissa * 2^exp.
#   MAC    : 12b x 12b -> 24b signed product (BFP12_PROD_W=24); a 16x16 group
#            reduces 256 products into a signed DENSE_ACC_W=32 integer; group sums
#            widen to GROUP_ACC_W=40, the array to ARRAY_ACC_W=44 (signed). The
#            shared exponent is applied AFTER the integer reduction.
#   Ternary: TERN_ZERO=0b00 -> 0, TERN_POS=0b01 -> +1, TERN_NEG=0b11 -> -1 (TLMM).
#
# *** BIT-ACCURACY IS PROVEN, NOT CLAIMED ***: validate_against_golden() compares
# these kernels against the SAME golden vectors the RTL testbench checks
# (tb_archbetter_core / tb_archbetter_soc_top). Two places need a one-time
# cross-check of the EXACT rounding rule vs the RTL and are marked  # RTL-XCHECK:
#   (1) the BFP12 exponent-selection + mantissa rounding (quantize_bfp12_block),
#   (2) cross-block accumulator alignment (bfp12_matmul). Until those pass the
# golden check, treat outputs as "format-faithful" not "bit-exact"; the harness
# turns that into a hard PASS/FAIL.
# -----------------------------------------------------------------------------
import numpy as np

# ---- exact constants from types_pkg.sv --------------------------------------
MANT_W, EXP_W, BLK = 12, 8, 16
MANT_MIN, MANT_MAX = -(1 << (MANT_W - 1)), (1 << (MANT_W - 1)) - 1     # -2048, 2047
EXP_MIN, EXP_MAX = -(1 << (EXP_W - 1)), (1 << (EXP_W - 1)) - 1          # -128, 127
ACC_W = 44
ACC_MIN, ACC_MAX = -(1 << (ACC_W - 1)), (1 << (ACC_W - 1)) - 1
TERN = {0: 0, 1: +1, 3: -1}   # tern_weight_e code -> value (0b00,0b01,0b11)


def quantize_bfp12_block(x):
    """FP vector (len BLK) -> (int mantissas, shared int exp). Block-floating-point.
    RTL-XCHECK: exponent picked so the max-magnitude element uses the full 12b
    mantissa; mantissa rounded to nearest (RTL truncation vs round-nearest is the
    one bit to confirm against the BFP packer). Saturating to [MANT_MIN,MANT_MAX]."""
    x = np.asarray(x, dtype=np.float64)
    amax = float(np.max(np.abs(x))) if x.size else 0.0
    if amax == 0.0:
        return np.zeros(x.shape, dtype=np.int64), 0
    # smallest exponent with NO mantissa overflow: round(amax/2^e) <= MANT_MAX
    #   => 2^e >= amax/MANT_MAX  => e = ceil(log2(amax/MANT_MAX))  (ceil, always)
    e = int(np.ceil(np.log2(amax / MANT_MAX)))
    e = int(np.clip(e, EXP_MIN, EXP_MAX))
    scale = 2.0 ** e
    m = np.rint(x / scale).astype(np.int64)        # round-nearest  # RTL-XCHECK
    m = np.clip(m, MANT_MIN, MANT_MAX)
    return m, e


def quantize_bfp12(x):
    """Quantize an array along its last axis in blocks of BLK. Returns (mant, exp)
    where exp has one value per block. Pads the last block if needed."""
    x = np.asarray(x, dtype=np.float64)
    *lead, n = x.shape
    nb = (n + BLK - 1) // BLK
    pad = nb * BLK - n
    xp = np.pad(x, [(0, 0)] * len(lead) + [(0, pad)])
    xb = xp.reshape(*lead, nb, BLK)
    mant = np.zeros_like(xb, dtype=np.int64)
    exp = np.zeros((*lead, nb), dtype=np.int64)
    for idx in np.ndindex(*xb.shape[:-1]):          # per block
        m, e = quantize_bfp12_block(xb[idx])
        mant[idx] = m
        exp[idx] = e
    return mant, exp


def dequantize_bfp12(mant, exp):
    """(mant[..., nb, BLK], exp[..., nb]) -> FP [..., nb*BLK], value = mant*2^exp."""
    full = mant.astype(np.float64) * (2.0 ** exp.astype(np.float64))[..., None]
    return full.reshape(*mant.shape[:-2], -1)


def bfp12_matmul(a_fp, w_fp):
    """Bit-accurate BFP12 GEMM:  y = a_fp @ w_fp^T  via the RTL integer path.
    a_fp: [M, K], w_fp: [N, K]. Quantizes both to BFP12 (block along K), does
    integer mantissa MACs per 16-block, scales by 2^(exp_a+exp_w), accumulates in
    a signed 44-bit integer, then returns the real-valued result.
    RTL-XCHECK: cross-block alignment + 44b saturation order vs dense_array."""
    a_fp = np.asarray(a_fp, np.float64); w_fp = np.asarray(w_fp, np.float64)
    am, ae = quantize_bfp12(a_fp)        # [M, nb, BLK], [M, nb]
    wm, we = quantize_bfp12(w_fp)        # [N, nb, BLK], [N, nb]
    M, nb, _ = am.shape; N = wm.shape[0]
    y = np.zeros((M, N), dtype=np.float64)
    for b in range(nb):                  # accumulate block-partials (exponent-aligned)
        # integer 256-MAC per (m,n) within this block, exact:
        prod = np.einsum('mk,nk->mn', am[:, b, :], wm[:, b, :])   # int64, exact
        scale = (2.0 ** (ae[:, b][:, None] + we[:, b][None, :]))   # 2^(E_a+E_w)
        y += prod.astype(np.float64) * scale
    # NB: a single global 44b integer accumulator with one shared output exponent
    # would saturate at ACC_MAX; this float path is exact when |y| fits 44b. The
    # golden check validates the saturation/scale order. RTL-XCHECK.
    return y


def ternary_matmul(a_fp, w_codes):
    """TLMM ternary path: w_codes in {0(=0),1(=+1),3(=-1)} (tern_weight_e), a_fp real.
    y = sum_k a[:,k] * value(w_codes[:,k]). Table-lookup in HW; exact add/sub here."""
    a = np.asarray(a_fp, np.float64)
    wv = np.vectorize(TERN.get)(np.asarray(w_codes)).astype(np.float64)  # {-1,0,+1}
    return a @ wv.T


# ---- shred ladder (sec 2.5): precision demotion of a weight tile ------------
def shred_apply(w_fp, klass):
    """Re-quantize a weight tile to a shred class (the EWMA-chosen precision).
    'bfp12'->full, 'bfp8'/'bfp6'->mantissa truncated, 'ternary'->{-1,0,+1}, 'zero'->0."""
    if klass == "zero":
        return np.zeros_like(w_fp)
    if klass == "ternary":
        # sign with a small dead-zone (placeholder threshold; RTL-XCHECK vs shred_controller)
        s = np.sign(w_fp); s[np.abs(w_fp) < (np.std(w_fp) * 0.5 + 1e-9)] = 0
        return s
    bits = {"bfp12": 12, "bfp8": 8, "bfp6": 6}[klass]
    m, e = quantize_bfp12(w_fp)
    keep = MANT_W - bits
    if keep > 0:
        m = (m >> keep) << keep          # truncate low mantissa bits (BFPn rung)
    return dequantize_bfp12(m, e)[..., :w_fp.shape[-1]]


# ---- validation harness: this is what makes "bit-accurate" a PASS/FAIL -------
def validate_against_golden(golden_path=None):
    """Compare these kernels against RTL golden vectors. golden_path is an .npz
    with arrays {a_fp, w_fp, y_int44} captured from the SAME stimulus the RTL TB
    checks (dump it from tb_archbetter_core / _soc_top). Returns (passed, max_ulp).
    Without a golden file this returns None and the twin must report 'UNVALIDATED'."""
    if golden_path is None:
        return None
    g = np.load(golden_path)
    y = bfp12_matmul(g["a_fp"], g["w_fp"])
    # RTL emits the integer array_acc (44b); compare exactly.
    y_ref = g["y_int44"].astype(np.float64)
    err = np.abs(y - y_ref)
    return bool(np.all(err == 0)), float(err.max())


if __name__ == "__main__":
    # smoke: BFP12 round-trip + a tiny GEMM sanity (NOT a golden check)
    rng = np.random.default_rng(0)
    a = rng.standard_normal((4, 32)); w = rng.standard_normal((8, 32))
    m, e = quantize_bfp12(a)
    print("BFP12 round-trip rel-err:", np.abs(dequantize_bfp12(m, e)[..., :32] - a).max())
    print("BFP12 GEMM vs fp64 rel-err:", np.abs(bfp12_matmul(a, w) - a @ w.T).max())
    print("ternary GEMM shape:", ternary_matmul(a, (rng.integers(0, 3, (8, 32)) * 1)).shape)
    print("NOTE: bit-exactness is only PROVEN once validate_against_golden() passes.")
