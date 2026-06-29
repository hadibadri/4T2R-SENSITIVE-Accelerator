# -----------------------------------------------------------------------------
# twin_runner.py  --  ArchBetter digital twin: run a REAL TinyLlama-1.1B through
# the bit-accurate ArchBetter numeric path, measure PERPLEXITY (the gate on the
# decode story), and project TTFT / throughput from the RTL-CALIBRATED cycle model.
#
# WHY THIS IS BOTH BIT-ACCURATE *AND* FAST (the v1 runner crashed Colab):
#   The BFP12 integer-MAC path is mathematically IDENTICAL to
#       (BFP12-rounded activation) @ (BFP12-rounded weight)
#   because  sum_k mant_a[k]*mant_w[k]*2^(Ea+Ew) == dequant(a) . dequant(w)  exactly.
#   The ONLY difference is the 44-bit accumulator saturation (the same RTL-XCHECK
#   item bitexact.py already flags). So instead of a per-block Python loop that
#   re-quantizes every weight on every forward (that was the crash: billions of
#   numpy.ndindex iterations + float64 weight copies), we:
#     (1) round each weight to its policy's BFP/shred/ternary value ONCE, in place;
#     (2) round activations to BFP12 with a tiny GPU pre-hook;
#     (3) run the model with the NORMAL fast (GPU) matmul.
#   Result is the same numbers, runs in seconds on a 4070 / minutes on Colab CPU.
#   bitexact.py stays the slow-but-literal integer reference for validate_against_golden.
#
#   TIMING is NOT taken from this Python (unrepresentative). TTFT/throughput come
#   from perf_projection() -- the analytical model calibrated to the 27165-cycle RTL
#   sim. That is the legitimate timing; wall-clock here would be meaningless.
# -----------------------------------------------------------------------------
import os
# Anaconda ships its own libiomp5; torch ships another. Two OpenMP runtimes in one
# process segfault the kernel silently on Windows. This makes them coexist. Must be
# set BEFORE torch is imported (torch is imported lazily inside the functions below).
os.environ.setdefault("KMP_DUPLICATE_LIB_OK", "TRUE")
import numpy as np

MODEL_ID = "TinyLlama/TinyLlama-1.1B-Chat-v1.0"
BLK = 16
_CACHE = {}


# ============================================================================
#  bit-accurate, GPU-native rounding  (matches bitexact.py formats exactly)
# ============================================================================
def _bfp_round(x, mant_bits=12, blk=BLK):
    """Round tensor x to block-floating-point along its LAST axis, in blocks of
    `blk`, with `mant_bits` signed mantissa + one shared exponent per block.
    mant_bits=12 -> BFP12 (dense path); 8/6 -> the shred rungs. Vectorized; no loop.
    Exponent rule matches bitexact.quantize_bfp12_block: e = ceil(log2(amax/qmax))."""
    import torch
    qmax = (1 << (mant_bits - 1)) - 1                       # 2047 / 127 / 31
    *lead, n = x.shape
    nb = (n + blk - 1) // blk
    pad = nb * blk - n
    if pad:
        x = torch.nn.functional.pad(x, (0, pad))
    xb = x.reshape(*lead, nb, blk)
    amax = xb.abs().amax(dim=-1, keepdim=True)
    e = torch.ceil(torch.log2((amax / qmax).clamp_min(1e-30)))
    e = torch.where(amax == 0, torch.zeros_like(e), e).clamp(-128, 127)
    scale = torch.exp2(e)
    m = torch.clamp(torch.round(xb / scale), -(qmax + 1), qmax)
    return (m * scale).reshape(*lead, nb * blk)[..., :n]


def _ternary(W):
    """Per-output-channel ternary {-1,0,+1} with absmean scaling (BitNet b1.58 / TWN).
    Each output channel (row of [out, in]) keeps its OWN scale:
        alpha_r = mean(|W[r, :]|);   Wq = clamp(round(W / alpha_r), -1, 1) * alpha_r.
    The dead-zone is implicit: |W| < alpha/2 rounds to 0. The previous blanket
    global-std version returned bare {-1,0,+1} with NO scale restoration, so weights
    collapsed to unit magnitude (~50x blowup) and perplexity exploded to 280k. THIS is
    the correct ternary the architecture's TLMM path actually represents (per-tile
    scale folds into the BFP exponent). RTL-XCHECK vs shred_controller ternary class."""
    import torch
    Wf = W.float()
    alpha = Wf.abs().mean(dim=1, keepdim=True).clamp_min(1e-8)     # per-output-channel
    q = torch.clamp(torch.round(Wf / alpha), -1.0, 1.0)
    return (q * alpha).to(W.dtype)


def _round_weight(W, policy, is_ffn):
    """Map a precision policy to the rounded effective weight (done ONCE per layer)."""
    if policy == "bfp12":
        return _bfp_round(W, 12)
    if policy == "bfp12_shred":
        # static shred proxy for the PPL sweep: demote to BFP8 rung (the EWMA usage
        # table picks the real per-tile class in HW; sec 2.5). RTL-XCHECK thresholds.
        return _bfp_round(W, 8)
    if policy == "ternary":
        return _ternary(W) if is_ffn else _bfp_round(W, 12)   # ternary ONLY on FFN
    return W                                                   # 'fp16' baseline


# ============================================================================
#  perplexity  --  the experiment that gates the decode story (A5/A6)
# ============================================================================
def _is_ffn(name):
    return any(k in name.lower() for k in ("mlp", "gate_proj", "up_proj", "down_proj"))


def _prepare_model(policy, device, model_id):
    """Load TinyLlama and apply the ArchBetter precision policy: weights rounded in
    place ONCE (BFP12 / BFP8-shred / per-channel-ternary), activations rounded to
    BFP12 by a forward pre-hook on every nn.Linear. Returns (model, tok, device, hooks).
    Shared by measure_perplexity (loss) and generate_through_arch (generation) so the
    numeric path is IDENTICAL in both -- a generated answer is produced by the same
    rounding the perplexity number measures."""
    import torch
    from transformers import AutoModelForCausalLM, AutoTokenizer
    device = device or ("cuda" if torch.cuda.is_available() else "cpu")
    dtype = torch.float16 if device == "cuda" else torch.float32
    tok = AutoTokenizer.from_pretrained(model_id)
    # `torch_dtype` on transformers<4.40, `dtype` on newer (the kwarg was renamed).
    # attn_implementation="eager" avoids the sdpa/flash backend, which can hard-crash
    # the kernel on a torch/transformers version skew; eager is plain math, always safe.
    load_kw = dict(low_cpu_mem_usage=True, attn_implementation="eager")
    try:
        model = AutoModelForCausalLM.from_pretrained(model_id, torch_dtype=dtype, **load_kw)
    except TypeError:
        try:
            model = AutoModelForCausalLM.from_pretrained(model_id, dtype=dtype, **load_kw)
        except TypeError:
            model = AutoModelForCausalLM.from_pretrained(model_id, torch_dtype=dtype)
    model = model.to(device).eval()

    hooks = []
    if policy != "fp16":
        def pre_hook(mod, inp):                                # round activation to BFP12
            return (_bfp_round(inp[0], 12),) + tuple(inp[1:])
        with torch.no_grad():
            for name, mod in model.named_modules():
                if isinstance(mod, torch.nn.Linear):
                    mod.weight.data.copy_(_round_weight(mod.weight.data, policy, _is_ffn(name)))
                    hooks.append(mod.register_forward_pre_hook(pre_hook))
    return model, tok, device, hooks


def measure_perplexity(policy="bfp12", n_tokens=512, device=None, model_id=MODEL_ID):
    """Run TinyLlama with the chosen ArchBetter precision policy; return PPL on a
    text window. Fast: a normal (GPU) forward. Reloads weights per call so each
    policy is clean."""
    import torch
    model, tok, device, hooks = _prepare_model(policy, device, model_id)
    text = _load_eval_text(n_tokens, tok)
    ids = tok(text, return_tensors="pt").input_ids[:, :min(n_tokens, 2048)].to(device)
    with torch.no_grad():
        loss = model(ids, labels=ids).loss
    ppl = float(torch.exp(loss))
    for h in hooks:
        h.remove()
    del model
    if device == "cuda":
        torch.cuda.empty_cache()
    return ppl


def generate_through_arch(prompt, policy="bfp12", max_new_tokens=40, device=None,
                          model_id=MODEL_ID):
    """ACTUALLY RUN the architecture: greedily generate an answer with weights and
    activations rounded to the ArchBetter `policy`. This is the qualitative companion
    to the perplexity sweep -- you ask a question and read the model's answer produced
    THROUGH our BFP12 / shred / ternary numeric path. Greedy (do_sample=False) so the
    comparison across policies is deterministic and fair. Returns the decoded string."""
    import torch
    model, tok, device, hooks = _prepare_model(policy, device, model_id)
    ids = tok(prompt, return_tensors="pt").input_ids.to(device)
    with torch.no_grad():
        out = model.generate(ids, max_new_tokens=max_new_tokens, do_sample=False,
                             pad_token_id=tok.eos_token_id)
    text = tok.decode(out[0], skip_special_tokens=True)
    for h in hooks:
        h.remove()
    del model
    if device == "cuda":
        torch.cuda.empty_cache()
    return text


def compare_policies_on_prompt(prompt, policies=("fp16", "bfp12", "bfp12_shred", "ternary"),
                               max_new_tokens=40, device=None):
    """Ask ONE question and print the answer under each precision policy, so you can
    see with your own eyes whether BFP12 / shred / ternary preserve the model's ability
    to answer. fp16 is the reference; if a policy still answers correctly, that policy
    is qualitatively safe (the perplexity number quantifies it)."""
    out = {}
    for pol in policies:
        print(f"\n=== [{pol}] ===", flush=True)
        ans = generate_through_arch(prompt, pol, max_new_tokens, device)
        out[pol] = ans
        print(ans, flush=True)
    return out


# Public-domain prose (Lewis Carroll, "Alice's Adventures in Wonderland", 1865 --
# out of copyright). Embedded so the twin needs NO `datasets`/`pyarrow` download:
# that library was segfaulting the kernel natively (uncatchable by try/except). For a
# precision SWEEP the absolute PPL depends on the text, but the DELTA vs fp16 (what
# gates the decode claim) is robust to the choice of genuine English prose.
_EVAL_TEXT = (
    "Alice was beginning to get very tired of sitting by her sister on the bank, and "
    "of having nothing to do: once or twice she had peeped into the book her sister was "
    "reading, but it had no pictures or conversations in it, and what is the use of a "
    "book, thought Alice, without pictures or conversations? So she was considering in "
    "her own mind, as well as she could, for the hot day made her feel very sleepy and "
    "stupid, whether the pleasure of making a daisy-chain would be worth the trouble of "
    "getting up and picking the daisies, when suddenly a White Rabbit with pink eyes ran "
    "close by her. There was nothing so very remarkable in that; nor did Alice think it "
    "so very much out of the way to hear the Rabbit say to itself, Oh dear! Oh dear! I "
    "shall be late! But when the Rabbit actually took a watch out of its waistcoat-pocket, "
    "and looked at it, and then hurried on, Alice started to her feet, for it flashed "
    "across her mind that she had never before seen a rabbit with either a waistcoat-pocket, "
    "or a watch to take out of it, and burning with curiosity, she ran across the field "
    "after it, and fortunately was just in time to see it pop down a large rabbit-hole "
    "under the hedge. In another moment down went Alice after it, never once considering "
    "how in the world she was to get out again. The rabbit-hole went straight on like a "
    "tunnel for some way, and then dipped suddenly down, so suddenly that Alice had not a "
    "moment to think about stopping herself before she found herself falling down a very "
    "deep well. Either the well was very deep, or she fell very slowly, for she had plenty "
    "of time as she went down to look about her and to wonder what was going to happen next. "
    "First, she tried to look down and make out what she was coming to, but it was too dark "
    "to see anything; then she looked at the sides of the well, and noticed that they were "
    "filled with cupboards and book-shelves; here and there she saw maps and pictures hung "
    "upon pegs. She took down a jar from one of the shelves as she passed; it was labelled "
    "Orange Marmalade, but to her great disappointment it was empty: she did not like to "
    "drop the jar for fear of killing somebody underneath, so managed to put it into one "
    "of the cupboards as she fell past it. Well, thought Alice to herself, after such a "
    "fall as this, I shall think nothing of tumbling down stairs! How brave they will all "
    "think me at home! Why, I would not say anything about it, even if I fell off the top "
    "of the house! which was very likely true. "
) * 4   # repeated to comfortably exceed any n_tokens we sweep


def _load_eval_text(n_tokens, tok):
    """Return embedded public-domain prose. No network, no `datasets` library (it was
    the segfault). Char budget generously exceeds n_tokens; tokenizer slice caps length."""
    return _EVAL_TEXT


def precision_sweep(n_tokens=512, device=None):
    """THE key experiment: PPL at each precision policy -> resolves A5/A6 and picks
    the decode tok/s out of 27..95. Returns {policy: ppl}. fp16 is the baseline."""
    out = {}
    for pol in ("fp16", "bfp12", "bfp12_shred", "ternary"):
        print(f"  [{pol}] running...", flush=True)
        try:
            out[pol] = measure_perplexity(pol, n_tokens, device)
            print(f"  [{pol}] PPL = {out[pol]:.4f}", flush=True)
        except Exception as e:
            out[pol] = f"ERR: {type(e).__name__}: {e}"
            print(f"  [{pol}] {out[pol]}", flush=True)
    return out


# ============================================================================
#  performance projection  --  calibrated cycle model (NOT python wall-clock)
# ============================================================================
# ---- MEASURED utilization (RTL sim, 2026-06-24, NOT assumed) ----------------
# tb_archbetter_soc_top_sustained: full SoC, 8x2=16 tiles, T=64, 8 distinct layers
# through every router + memory controller + AXI/DDR4. 27165 cyc/layer, 1080 checks,
# 0 errors. 16*64*512 = 524288 MAC / 27165 cyc = 19.3 MAC/cyc -> 3.77% end-to-end util.
# tb_archbetter_core_cont (4x2, compute-phase isolated): 109.45 MAC/cyc -> 21.38%,
# effective II = 4.68 cyc/beat (the bottleneck; ideal is 1.0).
ETA_PREFILL_MEASURED_E2E     = 0.0377   # [M] full SoC, incl. CSD fill + collector drain
ETA_PREFILL_MEASURED_COMPUTE = 0.2138   # [M] streaming phase only (II=4.68 limited)
ETA_PREFILL_TARGET           = 0.85     # [P] roadmap: needs II->1 AND T~1024 (NOT built)


def perf_projection(eta_prefill=ETA_PREFILL_MEASURED_COMPUTE, dram_bw_gbs=25.6,
                    decode_model="bfp12_shred", sigma=1.8, ternary_ffn=False):
    """TTFT / decode tok/s. eta_prefill now defaults to the MEASURED compute-phase
    util (0.2138, from tb_archbetter_core_cont STAGE 5), NOT the old 0.85 assumption.
    Pass ETA_PREFILL_MEASURED_E2E (0.0377) for the integrated sustained number, or
    ETA_PREFILL_TARGET (0.85) ONLY to show the II->1 / T~1024 roadmap ceiling -- label
    it [P]. decode tok/s is memory-bound (roofline), independent of compute util, but
    is itself a projection: peak DRAM bandwidth saturation is NOT yet measured."""
    F, N_PE = 225e6, 512
    peak_gmacs = N_PE * F / 1e9
    L, d, dff, nkv, h = 22, 2048, 5632, 4, 64
    mac_tok = L * (2*d*d + 2*d*(nkv*h) + 3*d*dff)            # 968.9 M
    params, b12, bt = 1.1e9, (12 + 8/16)/8, 1.58/8
    f_ffn, f_a = 0.786, 0.214
    if ternary_ffn:
        Btok = params*(f_a*b12/(sigma if "shred" in decode_model else 1) + f_ffn*bt)
    else:
        Btok = params*b12/(sigma if "shred" in decode_model else 1)
    R_dec = dram_bw_gbs*1e9 / Btok
    ttft = {S: S*mac_tok/(eta_prefill*peak_gmacs*1e9) for S in (32, 128, 512)}
    P_acc = 1.517
    return dict(prefill_gops=eta_prefill*peak_gmacs*2, ttft_s=ttft,
                decode_tok_s=R_dec, e_token_mJ=P_acc/R_dec*1e3,
                weight_GB_per_token=Btok/1e9, P_acc_W=P_acc)


if __name__ == "__main__":
    print("ArchBetter twin -- perf projection (calibrated cycle model):")
    for k, v in perf_projection().items():
        print(f"  {k}: {v}")
    print("\nFor perplexity: precision_sweep()  (needs torch+transformers; GPU recommended).")
