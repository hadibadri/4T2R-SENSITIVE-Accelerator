# -----------------------------------------------------------------------------
# competitors.py  --  AUTHENTIC, SOURCED cohort numbers for ArchBetter's eval.
#
#   *** HARD RULE: NOTHING IN THIS FILE IS INVENTED. ***
#   Every value is exactly as published, taken from docs/LITERATURE_SURVEY_2026.md
#   (each entry sourced to an arXiv id / venue). A field we cannot verify is
#   `None` -- NOT a guess. The viz layer renders `None` as "n/r" (not reported)
#   and DROPS that work from any axis it didn't report, so we never fabricate a
#   bar to make ourselves look better.
#
#   *** TWO COMPARABILITY CAVEATS (enforced downstream) ***
#   1. MODEL: cohort throughput is single-batch LLaMA2-7B unless `model` says
#      otherwise. ArchBetter's TinyLlama-1.1B tok/s is NOT raw-comparable to a 7B
#      number (smaller model => higher tok/s). Cross-work head-to-head must use
#      model-AGNOSTIC axes (GOPS/W, power, clock) OR same-model runs. tok/s always
#      carries its model label.
#   2. POWER SCOPE: 'core' (accelerator only) vs 'system' (board incl. HBM/DRAM).
#      ArchBetter reports CORE (DRAM external, CLAUDE.md sec 11). FlightLLM/EdgeLLM
#      report SYSTEM+HBM. Never compare raw watts across scopes without the label.
# -----------------------------------------------------------------------------

# Each entry: as-published. Unreported -> None. Citation is mandatory.
COHORT = [
    dict(name="FlightLLM", cite="FPGA'24 / arXiv:2401.03868",
         device="Alveo U280", cls="datacenter", clock_mhz=225,
         precision="W4A8 (sparse)", model="LLaMA2-7B",
         tok_s=55.0, tok_per_J=1.22, power_w=45.0, power_scope="system+HBM",
         gops=None, gops_per_w=None),
    dict(name="EdgeLLM", cite="TCAD'25 / arXiv:2407.21325",
         device="VCU128", cls="datacenter", clock_mhz=None,
         precision="FP16 MHA, FP16xINT4 FFN", model="LLaMA2-7B",
         tok_s=69.4, tok_per_J=1.22, power_w=56.8, power_scope="system+HBM",
         gops=None, gops_per_w=None),
    dict(name="TeLLMe", cite="arXiv:2504.16266 / 2510.15926",
         device="KV260", cls="edge", clock_mhz=250,
         precision="ternary 1.58b W / 8b A (TLMM)", model="edge model (paper); NOT 7B",
         tok_s=9.0, tok_per_J=None, power_w=7.0, power_scope="system (<7W envelope)",
         gops=None, gops_per_w=None),
    dict(name="PD-Swap", cite="arXiv:2512.11550",
         device="KV260", cls="edge", clock_mhz=None,
         precision="ternary + DPR prefill/decode swap", model="edge model (paper)",
         tok_s=27.0, tok_per_J=None, power_w=None, power_scope="system (KV260, few W)",
         gops=None, gops_per_w=None),
    dict(name="SwiftKV", cite="arXiv:2601.10953",
         device="edge MHA accel", cls="edge", clock_mhz=None,
         precision="edge attention", model="edge attention (paper)",
         tok_s=81.5, tok_per_J=None, power_w=None, power_scope="n/r",
         gops=1100.0, gops_per_w=60.12),
    dict(name="TeLLMe-v2 / TENET", cite="arXiv:2509.13765",
         device="Stratix 10 MX", cls="mid", clock_mhz=400,
         precision="sparse ternary LUT + HP cores", model="(paper); 4.3x A100 energy",
         tok_s=None, tok_per_J=None, power_w=None, power_scope="n/r",
         gops=None, gops_per_w=None),
    dict(name="F-BFQ", cite="arXiv:2510.13401",
         device="Kria", cls="edge", clock_mhz=None,
         precision="runtime-switchable BFP", model="(paper)",
         tok_s=5.2, tok_per_J=None, power_w=None, power_scope="system (Kria, few W)",
         gops=None, gops_per_w=None),
    # ASIC ceilings -- NOT apples-to-apples (related-work anchors, like our 4T2R macro)
    dict(name="Slim-Llama (ASIC)", cite="ISSCC'25 / IEEE 10904761",
         device="28nm ASIC", cls="asic", clock_mhz=None,
         precision="binary/ternary S-LUT", model="3B Llama",
         tok_s=None, tok_per_J=None, power_w=4.69e-3, power_scope="ASIC core",
         gops=None, gops_per_w=None, note="9 pJ/param, 20.25 mm^2 -- ceiling, not parity"),
    dict(name="4T2R ReRAM CIM (ASIC)", cite="our sec-ceiling macro",
         device="28nm ReRAM macro", cls="asic", clock_mhz=None,
         precision="analog 4T2R", model="single macro (no system)",
         tok_s=None, tok_per_J=None, power_w=None, power_scope="ASIC macro",
         gops=None, gops_per_w=None, note="59-95.3 TOPS/W -- analog ceiling, NOT parity (CLAUDE.md sec 0)"),
]

# ArchBetter operating points come from docs/ANALYTICS_MODEL.md, tier-labeled.
# These are OUR numbers; the viz marks measured [M] vs projected [P] distinctly so
# a reviewer instantly sees which of ours are data vs model.
ARCHBETTER = dict(
    name="ArchBetter (this work)", cite="this work",
    device="XCKU5P (xcku5p-ffvd900-3-e)", cls="edge", clock_mhz=225,
    precision="BFP12 dense + ternary TLMM + shred", power_scope="core (DRAM external)",
    # [A] architectural exact:
    gops_peak=230.4, gops_per_dsp_peak=0.450, gops_per_klut_peak=7.28,
    # [M] measured:
    power_w_core=1.517, power_w_total=1.556,
    gops_measured_k1=8.69, util_measured_k1=0.0377,
    # [P] projected (twin will validate -- perplexity-gated; see ANALYTICS_MODEL sec 7):
    gops_prefill_proj=196.0,                       # [P] util 0.85
    tok_s_decode_bfp12_shred=(27.0, 54.0),         # [P] @ 25.6 / 51.2 GB/s, near-lossless
    tok_s_decode_ternary=(47.0, 95.0),             # [P] PPL-gated
    tok_per_J_core=(2.5, 12.0),                    # [P] core scope
    model="TinyLlama-1.1B (twin) -- NOT 7B; see caveat",
    perplexity=None,                               # <-- the twin fills this; currently UNMEASURED
)

# Honesty banner the notebook prints before any chart.
HONESTY = """\
COMPARISON HONESTY (enforced):
 * tok/s across works is on DIFFERENT MODELS (cohort=LLaMA2-7B, ours=TinyLlama-1.1B).
   Raw tok/s is NOT comparable -> use GOPS/W & power for head-to-head; label model on tok/s.
 * Power scope differs (core vs system+HBM) -> annotated on every axis; never compared raw.
 * Unreported fields are 'n/r' and the work is DROPPED from that axis -- no invented bars.
 * Our projected [P] points (decode tok/s, prefill GOPS) are model estimates until the twin's
   perplexity result lands; rendered distinctly from measured [M].
 * ASIC rows (Slim-Llama, 4T2R) are CEILINGS, not parity claims (CLAUDE.md sec 0).
"""
