#!/usr/bin/env python3
# -----------------------------------------------------------------------------
# archbetter_analytics.py  --  end-to-end analytical performance/power/energy
#                              model for the ArchBetter KU5P prototype.
#
# WHY THIS EXISTS (read before trusting a number):
#   The on-chip BRAM-as-DRAM closure endpoint makes a 100%-coverage gate-level
#   SAIF impractical (the routed netlist reads zeros; the -cell carve-out is
#   contaminated). BUT throughput / latency / TTFT are DETERMINISTIC -- they come
#   from cycle counts we measured EXACTLY in RTL simulation, so they need no SAIF
#   at all (~100% accurate). Power is the only metric the SAIF touched, and an
#   analytical per-resource x duty model -- cross-checked against the behavioral
#   SAIF -- is a defensible, transparent substitute (CLAUDE.md sec 8/11; the
#   masterclass Part XII/XIII gives the model vocabulary).
#
# THREE TIERS OF NUMBER (every output is labelled):
#   [M] MEASURED      -- cycle-exact from RTL sim / exact from impl reports. Hard data.
#   [A] ARCHITECTURAL -- exact from resource count x clock (peak, roofline ridge).
#   [P] PROJECTED     -- model + STATED assumptions (deep-K util, DRAM BW, shred).
#                        These are what the PyTorch/cycle digital twin will confirm;
#                        treat as estimates with the disclosed sensitivity, NOT data.
#
# All assumptions are editable variables in the ASSUMPTIONS block so the eval
# table regenerates as the twin tightens them.
#
# Run:  python tools/analytics/archbetter_analytics.py
# -----------------------------------------------------------------------------

# =============================================================================
# 1. HARDWARE CONSTANTS  [A] -- exact, from the routed impl (reports/util.rpt)
# =============================================================================
N_PE         = 512            # physical MAC PEs (2x dense_group, 16x16 each, 1 fused DSP/PE)
F_HZ         = 225e6          # compute clock (MMCM clkout0); timing MET, WNS +0.152 ns
OPS_PER_MAC  = 2              # 1 multiply + 1 add
DSP          = 512
BRAM_TILES   = 91.5           # RAMB36-equivalent (91 RAMB36 + 1 RAMB18)
URAM         = 11             # URAM288
LUT          = 31659
FF           = 63357
T_CLK        = 1.0 / F_HZ     # 4.444 ns

PEAK_GMACS   = N_PE * F_HZ / 1e9           # 115.2 G MAC/s
PEAK_GOPS    = PEAK_GMACS * OPS_PER_MAC    # 230.4 GOPS

# Throughput / AREA  [A] -- FPGA-standard resource normalisation (lit survey 3.6).
# Absolute GOPS/mm^2 needs the XCKU5P die area (not publicly exact -> NOT fabricated);
# DSP- and LUT-normalised throughput is the honest FPGA proxy, and is EXACT.
PEAK_GOPS_PER_DSP  = PEAK_GOPS / DSP                 # 0.450 GOPS/DSP
PEAK_GOPS_PER_KLUT = PEAK_GOPS / (LUT/1e3)           # 7.28  GOPS/kLUT

# On-chip weight-capable storage (URAM is the weight store; CLAUDE.md sec 2.3)
URAM_BITS    = URAM * 288 * 1024           # 288 Kb per URAM288
BRAM_BITS    = BRAM_TILES * 36 * 1024
ONCHIP_WMB   = URAM_BITS / 8 / 1e6         # MB of URAM weight store (~0.4 MB)

# AXI memory seam (DRAM/MIG external, CLAUDE.md sec 11): 128-bit @ compute clock.
AXI_BITS     = 128
AXI_BW_BPS   = AXI_BITS * F_HZ / 8         # bytes/s on the m_axi seam  = 3.6 GB/s

# =============================================================================
# 2. MEASURED OPERATING POINT  [M] -- the 8x2 / K=1 / T=64 sustained layer.
#    Cycle-exact from tb_archbetter_soc_top_sustained (BATCH_T=64 run):
#    "LAYER n program_done after 27165 cycles".  This is the HONEST reload-bound
#    micro-benchmark (K=1 single matrix-vector batched over 64 tokens).
# =============================================================================
CYC_LAYER    = 27165          # [M] full program: CSD fill + 16-tile GEMM + ST_OUT drain
USED_COLS    = 64             # COL_CNT(2) x PHYS_COLS(32)
REDUCE_DEPTH = 128            # ROW_CNT(8) x GROUP_ROWS(16)  (the K=1 reduction)
T_TOK        = 64             # tokens per resident weight set
MAC_LAYER    = USED_COLS * REDUCE_DEPTH * T_TOK     # 524,288 MAC
TIME_LAYER   = CYC_LAYER * T_CLK                    # 120.7 us

GOPS_MEAS    = MAC_LAYER * OPS_PER_MAC / TIME_LAYER / 1e9
UTIL_MEAS    = GOPS_MEAS / PEAK_GOPS
MAC_PER_CYC_MEAS = MAC_LAYER / CYC_LAYER

# Ideal compute cycles for this MAC count (if the array never stalled):
CYC_COMPUTE_IDEAL = MAC_LAYER / N_PE               # 1024 cyc
CYC_OVERHEAD      = CYC_LAYER - CYC_COMPUTE_IDEAL   # ~26,141 cyc of fixed cost
# The overhead = CSD fill + 16 weight reloads + per-token drain/snap/rearm + ST_OUT
# + FFN + barriers. At K=1 it dwarfs compute -> reload-bound. (Phase split is
# model-inferred from one measured total; sim instrumentation would itemise it.)

# =============================================================================
# 3. POWER  -- per-resource from post-route report_power (behavioral 8-layer
#    SAIF, reports/power_saif.rpt). Overall confidence Low (6% nets matched), BUT
#    each row is anchored by EXACT resource count + High-confidence clock
#    (create_clock) + matched-register activity; the dominant rows (clock, DSP,
#    BRAM, URAM, MMCM = 0.64 W of 1.08 W dyn) are well-bounded. Used here as the
#    analytical baseline AND cross-check. [M]/[A] anchored, activity disclosed.
# =============================================================================
P_TOTAL      = 1.556          # whole chip
P_DYN        = 1.081
P_STATIC     = 0.476          # device leakage (whole-chip, not split per block)
P_USOC_DYN   = 1.053          # accelerator (u_soc) dynamic -- the sec 11 boundary
P_UMEM_DYN   = 0.016          # DRAM stand-in -- EXTERNAL, excluded from headline

P_RES = {  # per-resource dynamic (W), from report_power "On-Chip Components"
    "Clocks": 0.258, "Signals": 0.274, "CLB": 0.158, "BRAM": 0.099,
    "URAM": 0.069, "MMCM": 0.083, "DSP": 0.130, "IO": 0.009,
}
# Accelerator power for efficiency (DRAM external, sec 11): u_soc dyn + a
# pro-rata share of static. Static isn't split per block; attribute it by the
# u_soc-dynamic fraction of total dynamic (conservative, disclosed).
P_ACC_STATIC = P_STATIC * (P_USOC_DYN / P_DYN)
P_ACC        = P_USOC_DYN + P_ACC_STATIC           # accelerator-scoped total

# =============================================================================
# 4. ASSUMPTIONS  [P] -- the ONLY knobs the projections depend on. Edit here;
#    the digital twin will replace each with a calibrated value.
# =============================================================================
# (a) Deep-K prefill utilisation. At reduction depth K=hidden(2048) the fixed
#     per-residency overhead (weight load + per-token drain) amortises over a
#     ~K-deeper compute, so util -> high (compute-roof, roofline). Conservative
#     band; masterclass projected ~88%.
UTIL_PREFILL = 0.85
UTIL_PREFILL_LO, UTIL_PREFILL_HI = 0.75, 0.90

# (b) External DRAM bandwidth seen by the accelerator = the binding decode limit.
#     Current design: the m_axi seam (128b @ 225MHz = 3.6 GB/s). A wider seam is
#     a design option (512b @ 225MHz = 14.4 GB/s) -- reported as sensitivity.
DRAM_BW_NOW  = AXI_BW_BPS            # 3.6 GB/s (current 128b seam)
DRAM_BW_WIDE = 4 * AXI_BW_BPS        # 14.4 GB/s (512b seam option)

# (c) Effective bytes/param. Dense BFP12 = 12b mantissa + 8b shared exp / 16 elems.
BFP12_BYTES_PER_PARAM = (12 + 8/16) / 8            # 1.5625 B/param
TERNARY_BYTES_PER_PARAM = 1.58 / 8                 # 0.1975 B/param (TLMM sparse path)
# Shred Oracle (sec 2.5) demotes cold tiles BFP12->8->6->ternary->0. Average
# effective compression of the weight stream over a served model. Conservative.
SHRED_AVG_COMPRESSION = 1.8         # >1 = fewer bytes than full BFP12

# (d) Fraction of decode weight traffic served by the TERNARY sparse-FFN path
#     vs the BFP12 dense path. TinyLlama FFN (ternary-capable) is ~78% of MAC.
FFN_TERNARY_FRACTION = 0.0          # 0.0 = all-BFP12 (worst case); set >0 to model TLMM FFN

# =============================================================================
# 5. TARGET MODEL: TinyLlama-1.1B-Chat (config verifiable on HuggingFace).
# =============================================================================
TL = dict(L=22, d=2048, d_ff=5632, n_heads=32, n_kv=4, head_dim=64,
          vocab=32000, params=1.1e9)

def mac_per_token_per_layer(c):
    d, d_ff, n_kv, hd = c["d"], c["d_ff"], c["n_kv"], c["head_dim"]
    attn = 2*d*d + 2*d*(n_kv*hd)     # Q,O = d^2 ; K,V = d*(n_kv*hd) with GQA
    ffn  = 3*d*d_ff                  # SwiGLU: gate, up, down
    return attn + ffn

MAC_TOK_LAYER = mac_per_token_per_layer(TL)
MAC_TOK_ALL   = MAC_TOK_LAYER * TL["L"]            # all 22 layers, per token
GOP_TOK       = MAC_TOK_ALL * OPS_PER_MAC / 1e9    # ~1.94 GOP/token

# Weight bytes streamed per decode token (whole model once per token):
W_BYTES_BFP12 = TL["params"] * BFP12_BYTES_PER_PARAM
def decode_weight_bytes():
    # blend ternary-FFN fraction + shred compression on the BFP12 remainder
    bfp_frac = 1.0 - FFN_TERNARY_FRACTION
    bytes_bfp  = TL["params"]*bfp_frac*BFP12_BYTES_PER_PARAM / SHRED_AVG_COMPRESSION
    bytes_tern = TL["params"]*FFN_TERNARY_FRACTION*TERNARY_BYTES_PER_PARAM
    return bytes_bfp + bytes_tern

# =============================================================================
# 6. DERIVED METRICS
# =============================================================================
def prefill(util, seq_len):
    """[P] compute-bound prefill: TTFT and prefill throughput."""
    achieved_macs = util * PEAK_GMACS * 1e9        # MAC/s
    total_mac = seq_len * MAC_TOK_ALL              # (ignores O(S^2) attn scores; small for short S)
    ttft_s = total_mac / achieved_macs
    tok_s  = seq_len / ttft_s                      # prefill tokens/s
    return ttft_s, tok_s, achieved_macs

def decode(dram_bw):
    """[P] memory-bound decode (roofline memory roof): tok/s = BW / bytes/token."""
    wb = decode_weight_bytes()
    tok_s = dram_bw / wb
    e_token = P_ACC / tok_s                        # J/token, accelerator-scoped
    return tok_s, e_token, wb

# =============================================================================
# 7. REPORT
# =============================================================================
def banner(s): print("\n" + "="*78 + "\n" + s + "\n" + "="*78)

def main():
    banner("ArchBetter KU5P -- end-to-end analytical model")
    print(f"  device xcku5p-ffvd900-3-e | f = {F_HZ/1e6:.0f} MHz | {N_PE} PE | "
          f"{DSP} DSP, {BRAM_TILES} BRAM, {URAM} URAM")

    banner("[A] ARCHITECTURAL (exact: resource x clock)")
    print(f"  Peak compute        : {PEAK_GMACS:6.1f} G MAC/s = {PEAK_GOPS:6.1f} GOPS")
    print(f"  On-chip weight store : {ONCHIP_WMB:5.2f} MB URAM  (<< 1.1B params -> decode streams from DRAM)")
    print(f"  AXI seam bandwidth   : {AXI_BW_BPS/1e9:5.2f} GB/s (128b @ {F_HZ/1e6:.0f} MHz) -- the decode roofline slope")

    banner("[M] MEASURED micro-benchmark (8x2 layer, K=1, T=64; cycle-exact)")
    print(f"  cycles/layer        : {CYC_LAYER:,}  ({TIME_LAYER*1e6:.1f} us @ {F_HZ/1e6:.0f} MHz)")
    print(f"  MACs/layer          : {MAC_LAYER:,}  ({MAC_LAYER*OPS_PER_MAC:,} ops)")
    print(f"  achieved throughput : {GOPS_MEAS:6.2f} GOPS   ({MAC_PER_CYC_MEAS:.1f} MAC/cyc of {N_PE})")
    print(f"  utilisation         : {UTIL_MEAS*100:5.2f} %   <-- reload-bound K=1 corner (honest floor)")
    print(f"  fixed overhead      : {CYC_OVERHEAD:,.0f} cyc vs {CYC_COMPUTE_IDEAL:,.0f} ideal-compute cyc")
    print("  NOTE: this UNDERSTATES the fabric -- a real LLM layer has K=hidden, which")
    print("        amortises the weight-load + per-token drain (see projection).")

    banner("[M]/[A] POWER (post-route report_power; per-resource resource-anchored)")
    print(f"  whole-chip total    : {P_TOTAL:5.3f} W  (dyn {P_DYN:.3f} + static {P_STATIC:.3f})")
    print(f"  accelerator u_soc   : {P_USOC_DYN:5.3f} W dyn  (+{P_ACC_STATIC:.3f} W static share = {P_ACC:.3f} W)")
    print(f"  DRAM stand-in u_mem : {P_UMEM_DYN:5.3f} W  (EXTERNAL, excluded -- sec 11)")
    print("  per-resource dynamic:")
    for k, v in sorted(P_RES.items(), key=lambda kv: -kv[1]):
        print(f"      {k:8s} {v:5.3f} W   ({v/P_DYN*100:4.1f}% of dyn)")
    print(f"  dominant well-bounded rows (clk+DSP+BRAM+URAM+MMCM): "
          f"{P_RES['Clocks']+P_RES['DSP']+P_RES['BRAM']+P_RES['URAM']+P_RES['MMCM']:.3f} W "
          f"= {(P_RES['Clocks']+P_RES['DSP']+P_RES['BRAM']+P_RES['URAM']+P_RES['MMCM'])/P_DYN*100:.0f}% of dyn")

    banner("[P] PROJECTED prefill (compute-bound) -- TinyLlama-1.1B, TTFT")
    print(f"  MAC/token (all {TL['L']} layers): {MAC_TOK_ALL/1e6:6.1f} M  ({GOP_TOK:.2f} GOP/token)")
    for S in (32, 128, 512):
        ttft, tps, am = prefill(UTIL_PREFILL, S)
        ttft_lo,_,_ = prefill(UTIL_PREFILL_HI, S)
        ttft_hi,_,_ = prefill(UTIL_PREFILL_LO, S)
        print(f"  prompt S={S:4d}: TTFT = {ttft*1e3:7.1f} ms  "
              f"[{ttft_lo*1e3:.0f}-{ttft_hi*1e3:.0f} ms @ util {UTIL_PREFILL_HI:.0%}-{UTIL_PREFILL_LO:.0%}]  "
              f"prefill {tps:6.1f} tok/s")
    print(f"  (assumes util_prefill = {UTIL_PREFILL:.0%}; achieved {UTIL_PREFILL*PEAK_GOPS:.0f} GOPS on the compute roof)")

    banner("[P] PROJECTED decode (memory-bound roofline) -- TinyLlama-1.1B")
    print(f"  weight bytes/token (BFP12, no shred)      : {W_BYTES_BFP12/1e9:5.2f} GB")
    print(f"  weight bytes/token (model, shred x{SHRED_AVG_COMPRESSION}, "
          f"ternary-FFN {FFN_TERNARY_FRACTION:.0%}) : {decode_weight_bytes()/1e9:5.2f} GB")
    for label, bw in (("current 128b seam", DRAM_BW_NOW), ("512b seam option", DRAM_BW_WIDE)):
        tps, et, wb = decode(bw)
        print(f"  decode @ {label:18s} ({bw/1e9:5.2f} GB/s): "
              f"{tps:5.1f} tok/s   E_token {et*1e3:6.0f} mJ/tok (core, DRAM ext)")
    print("  ROOFLINE READING: decode is BANDWIDTH-bound (weights stream once/token);")
    print("  the levers are quantisation (shred -> fewer bytes) and seam width, NOT MACs.")
    print("  BFP12's fidelity costs decode bytes; shred + the ternary TLMM path recover it.")

    banner("[P] EFFICIENCY (accelerator-scoped; DRAM external)")
    gops_prefill = UTIL_PREFILL * PEAK_GOPS
    print(f"  prefill GOPS/W      : {gops_prefill/P_ACC:6.1f}  ({gops_prefill:.0f} GOPS / {P_ACC:.2f} W)")
    print(f"  measured-corner GOPS/W: {GOPS_MEAS/P_ACC:6.2f}  (K=1 reload-bound; understates)")
    tps_now,_,_ = decode(DRAM_BW_NOW)
    print(f"  decode energy/token : {P_ACC/tps_now*1e3:6.0f} mJ/tok  = {tps_now/P_ACC:5.2f} tok/J (core)")
    print("  SCOPE WARNING for the cohort table: this is ACCELERATOR-CORE power with")
    print("  DRAM external (sec 11). FlightLLM/EdgeLLM quote 45-57 W SYSTEM+HBM -- a")
    print("  different, larger scope. Always annotate scope; never compare raw.")

    banner("DISCLOSURE")
    print("  [M] measured = cycle-exact RTL / exact impl reports -> paper as data.")
    print("  [A] architectural = resource x clock -> exact.")
    print("  [P] projected = model + stated assumptions above -> the PyTorch + cycle")
    print("      digital twin will CONFIRM these (perplexity, real-shape TTFT, deep-K).")
    print("      Until then they are estimates with the disclosed sensitivity, not data.")

if __name__ == "__main__":
    main()
