# ArchBetter — The Masterclass

### An end-to-end course on LLM-accelerator SoC design, from a single memristor cell to a published chip

> **How to read this document.** Every major concept is introduced **twice**: first a *plain-language* paragraph (the intuition — read this even if you skip everything else), then a *technical* paragraph (the math, the bit-widths, the protocol, the trade-off). Terms in **bold** are defined where they first appear and again in the Glossary (Part XVIII). Where a concept maps to a specific file in this repo, the file is named in `monospace`. Cross-references look like *(see Part VII)*.
>
> This is written to make you fluent enough to defend ArchBetter in front of a TVLSI reviewer **and** to sit at an NVIDIA/Google-TPU architecture review and follow every word. It assumes you are smart but does not assume you already know the jargon. Nothing is hand-waved; where a number is unknown we say "TBD" rather than inventing it.
>
> **The spine of the whole field, in one sentence:** *a neural network is a pile of matrix multiplies; a hardware accelerator is a machine that moves data so that multipliers are never idle; and every design decision is a fight between three enemies — not enough compute, not enough memory bandwidth, and not enough energy budget.* Keep that sentence in your head and everything below is commentary on it.

---

## Table of Contents

- **Part 0** — The mental model: compute, memory, energy (the three walls)
- **Part I** — What an LLM actually is (transformers, attention, FFN, prefill vs decode, KV cache)
- **Part II** — Numbers in hardware (fixed point, floating point, block floating point, quantization, ternary)
- **Part III** — From electrons to a multiply: memristors, ReRAM, 4T2R, compute-in-memory, the digital twin
- **Part IV** — The Processing Element and the DSP48E2 (the MAC, pipelining, the fused MACC)
- **Part V** — The dense core: groups, systolic arrays, logical-vs-physical, the two reductions
- **Part VI** — The sparse core: ternary weights and table-lookup multiplication (TLMM)
- **Part VII** — Memory hierarchy: DRAM, URAM, BRAM, LUTRAM, ping-pong, the CSD engine, the KV cache
- **Part VIII** — Interconnect: the NoC, circuit-switched vs packet-switched, why "no AXI"
- **Part IX** — The control plane: the macro-ISA, the dispatcher, asymmetric pipelining, the tile walker
- **Part X** — The three novelties: Weight Shredding, AC drift refresh, qN→BFP12 dequant
- **Part XI** — Mapping an LLM onto the silicon: tiling, dataflow taxonomy, the schedule
- **Part XII** — Performance modeling: latency, throughput, GOPS, the roofline, TTFT, Amdahl
- **Part XIII** — Power and energy: dynamic vs static, switching activity, SAIF, P=αCV²f, energy per token
- **Part XIV** — FPGA implementation: synthesis, place, route, STA, slack, CDC, methodology, OOC
- **Part XV** — Verification: testbenches, golden models, scoreboards, assertions, coverage
- **Part XVI** — SoC integration and closure: the wrapper, the MIG, clocking, the path to a bitstream
- **Part XVII** — The SOTA landscape and how to compare honestly (FlightLLM, EdgeLLM, TeLLMe, CIM macros)
- **Part XVIII** — Glossary of every term
- **Part XIX** — Flaws, risks, and open problems (read this before you believe any claim)

---

## Part 0 — The mental model: the three walls

**Plain version.** Imagine a kitchen. The *chefs* are your multipliers (they do the actual work). The *pantry* is your memory (where ingredients live). The *hallway* between pantry and kitchen is your memory bandwidth. And the *electricity bill* is your power budget. You can have a thousand chefs, but if the hallway only fits one waiter, the chefs stand around idle. You can have a huge pantry, but if it's far away (off-chip DRAM), every trip is slow and expensive. Great accelerator design is *kitchen logistics*: keep the chefs busy, keep ingredients close, and don't blow the electricity bill. Almost every clever idea in this field — caching, tiling, dataflow, quantization, compute-in-memory — is one of those three problems being attacked.

**Technical version.** Every workload sits somewhere on the **roofline model**. Define **arithmetic intensity** `I = (FLOPs performed) / (bytes moved from memory)`, in FLOP/byte. A machine has two ceilings: **peak compute** `P_max` (FLOP/s) and **peak memory bandwidth** `B` (byte/s). Achievable performance is `P = min(P_max, I · B)`. If `I` is low you are **memory-bound** (the sloped part of the roof, `I·B`); if `I` is high you are **compute-bound** (the flat part, `P_max`). The crossover is the **ridge point** `I* = P_max / B`. LLM **prefill** has high `I` (a big matrix times a big matrix reuses each weight many times) → compute-bound. LLM **decode** has `I ≈ 1` (a big matrix times *one* vector reuses each weight exactly once) → memory-bound. This single fact dictates the entire architecture: prefill wants maximum MACs; decode wants maximum bandwidth and weight reuse. ArchBetter's ping-pong URAM, weight-streaming dataflow, and the (planned) resident-weight decode mode all exist to fight on these two fronts. The third wall, **energy**, is governed by `E = P · t` and ultimately by `E_op` (energy per operation); we return to it in Part XIII, but note now that *moving* a byte from DRAM costs ~100–1000× more energy than *computing* with it — which is why "compute-in-memory" (Part III) is a holy grail.

The rest of this course is the story of one specific machine — ArchBetter, on a Xilinx Kintex UltraScale+ XCKU5P FPGA — fighting these three walls to serve a TinyLlama/Llama-class model at the edge.

---

## Part I — What an LLM actually is

### I.1 The 30-second version

**Plain version.** A large language model (LLM) is a function that takes a sequence of words (more precisely, **tokens**) and predicts the next token. You run it in a loop: feed in "The cat sat on the", it predicts "mat", you append "mat", feed the whole thing back, it predicts the next word, and so on. That loop is called **autoregressive generation**. The model is "large" because it has billions of **parameters** (the numbers it learned during training). Running a trained model to get predictions is **inference** — that's all hardware accelerators like ArchBetter do; they don't train, they infer.

**Technical version.** An LLM is a parameterized function `f_θ: tokens → probability distribution over vocabulary`. The parameters `θ` (the **weights**) are fixed after training. Inference computes `p(x_{t+1} | x_1...x_t) = softmax(f_θ(x_1...x_t))`, samples a token, appends it, and repeats. The dominant modern architecture is the **decoder-only Transformer** (GPT, Llama, TinyLlama). Compute cost is dominated by **matrix multiplications** (GEMM — General Matrix Multiply) inside repeated **Transformer blocks**. For a model with hidden dimension `d`, sequence length `n`, and `L` layers, prefill cost scales as `O(L · n · d²)` for the weight matmuls plus `O(L · n² · d)` for attention; decode cost per token scales as `O(L · d²)`.

### I.2 Tokens and embeddings

**Plain version.** Computers don't see words, they see numbers. A **tokenizer** chops text into pieces (whole words, word-fragments, or characters) called tokens, each with an integer ID. An **embedding** table turns each token ID into a vector of numbers (say 2048 numbers for TinyLlama) — a point in a high-dimensional space where "king" and "queen" land near each other. That vector is what flows through the network.

**Technical version.** Tokenization is typically **Byte-Pair Encoding (BPE)** or **SentencePiece**: a fixed vocabulary of `V` sub-word units (TinyLlama: V=32000). The embedding is a lookup into a learned matrix `E ∈ ℝ^{V×d}`; token id `i` → row `E[i] ∈ ℝ^d`. `d` is the **hidden size** / **model dimension** (TinyLlama d=2048). The sequence of `n` embeddings forms the activation matrix `X ∈ ℝ^{n×d}`, which is what every subsequent layer transforms. There is no matmul here — it's a **gather** — but it sets the shapes (`d`) that make every later matmul expensive.

### I.3 The Transformer block — the unit that repeats

**Plain version.** The network is a stack of identical blocks (TinyLlama has 22). Each block does two things in sequence: (1) **attention**, where each token "looks at" the other tokens and pulls in relevant context, and (2) a **feed-forward network (FFN)**, a fat two-layer perceptron applied to each token independently. Around each is a **residual connection** (add the input back to the output, so information can skip) and a **normalization** step (rescale numbers so they don't blow up). Stacking 22 of these is what gives the model its power.

**Technical version.** One pre-norm decoder block computes:
```
h  = x + Attention(RMSNorm(x))
y  = h + FFN(RMSNorm(h))
```
- **RMSNorm** (Llama uses RMSNorm, not LayerNorm): `RMSNorm(x) = x / sqrt(mean(x²) + ε) · g`, with learned gain `g`. Cheap (a reduction + reciprocal-sqrt + elementwise multiply), but it is a *non-GEMM* op — a serial dependency that accelerators must not stall on.
- **Attention** (next subsection).
- **FFN**: `FFN(x) = W_down · σ(W_gate · x ⊙ W_up · x)` for the **SwiGLU** variant Llama uses (σ = SiLU/swish). Two or three big matmuls with an inner dimension `d_ff` (TinyLlama d_ff=5632) larger than `d`. The FFN is ~⅔ of the parameter count and the prime target for the **sparse/ternary core** (Part VI) because FFN weights tolerate aggressive quantization.
- **Residual adds** are elementwise; cheap in FLOPs but they force *accumulation precision* discipline (you add a small correction to a large running value, so you need headroom — this is one reason ArchBetter accumulates in 44-bit `array_acc_t`, Part IV).

### I.4 Attention — the part that makes it a "Transformer"

**Plain version.** For each token, the model creates three vectors: a **Query** ("what am I looking for?"), a **Key** ("what do I offer?"), and a **Value** ("what do I pass along if chosen?"). Each token's Query is compared against every other token's Key to get **attention scores** (how relevant is each other token?), those scores are turned into weights that sum to 1 (**softmax**), and the output is the weighted sum of Values. So attention is "soft, learned lookup": each token retrieves a blend of information from the tokens it cares about.

**Technical version.** For input `X ∈ ℝ^{n×d}`: `Q = X W_Q`, `K = X W_K`, `V = X W_V` (three GEMMs). Scores `S = QKᵀ / sqrt(d_head) ∈ ℝ^{n×n}`, then `A = softmax(S)` row-wise, then `O = A V ∈ ℝ^{n×d}`, then output projection `X W_O`. Multi-head attention splits `d` into `H` heads of size `d_head = d/H` and does this per head in parallel. **Causal masking** (decoder) zeroes the upper triangle of `S` so a token can't see the future. Modern Llama uses **Grouped-Query Attention (GQA)** — fewer K/V heads than Q heads — specifically to shrink the **KV cache** (below). The `QKᵀ` and `AV` matmuls are `O(n²)` in sequence length, which is why long context is expensive and why attention is *bandwidth*-sensitive (it streams the whole KV history).

### I.5 The KV cache — the single most important inference data structure

**Plain version.** During generation, token #500 needs to attend to tokens #1–#499. Those earlier tokens' Key and Value vectors don't change — so it would be insane to recompute them every step. Instead you **cache** them: compute each token's K and V once, store them, and reuse. This **KV cache** grows by one entry per generated token. It's what makes decode fast (you only compute the new token) — but it's also a memory hog: it can grow to gigabytes for long contexts, and *every* decode step must read the *entire* KV cache. That read is the main reason decode is memory-bound.

**Technical version.** The KV cache stores `K, V ∈ ℝ^{n×d_kv}` per layer, growing with `n`. Size = `2 · L · n · d_kv · bytes_per_elem`. Each decode step appends one row and reads all `n` rows for the `AV`/`QKᵀ` products → memory traffic `O(L·n·d_kv)` per token, with arithmetic intensity ≈ 1 (each cached byte is used once) → **memory-bound**, which is exactly why the KV cache earns dedicated on-chip storage. In ArchBetter the KV cache lives in **Block RAM** (BRAM), not URAM: `KV_DATA_W = 144` bits per entry, `KV_DEPTH = 16384` entries → 2.36 Mbit ≈ **64 RAMB36 tiles** (this is the entire 64-BRAM utilization you saw in `util.rpt`). It is written via the `OP_KV_WRITE` macro and read via `OP_KV_READ`; its address map is owned by the Memory Manager. Putting it in BRAM (fast, on-chip, random-access) rather than URAM keeps the wide weight/activation streams in URAM uncontended.

### I.6 Prefill vs Decode — burn this into your memory

**Plain version.** Generating text has two phases. **Prefill**: you feed in the whole prompt at once (say 500 tokens). The hardware can process them as one big batch — lots of parallel work, multipliers stay busy. This produces the **first** output token, and the time to get it is the **Time To First Token (TTFT)**. **Decode**: now you generate tokens one at a time, each depending on the last. Each step does relatively little math but must touch all the weights and the whole KV cache — so the multipliers are starved and you're limited by how fast you can *fetch*, not *compute*. Prefill is a sprint; decode is a slow march. Users feel prefill as "lag before it starts typing" and decode as "typing speed (tokens/second)."

**Technical version.** Prefill processes `n_prompt` tokens as a `[n_prompt × d] · [d × d]` GEMM → arithmetic intensity ∝ `n_prompt` (each weight reused `n_prompt` times) → compute-bound; metric = **prefill throughput** (tokens/s) and **TTFT** (latency to first token). Decode processes one token: `[1 × d] · [d × d]` GEMV (matrix-**vector**) → each weight read once, `I ≈ 1` → memory-bound; metric = **decode throughput** (tokens/s) and per-token latency. **This is the crux of your current measurement problem:** `tb_archbetter_core` at `K_TILE=1` is a *decode-style GEMV with per-tile weight reload*, so it measured 0.11% DSP utilization — that is the *expected* signature of a memory/reload-bound decode workload running without weight residency, **not** a broken fabric. A correct benchmark reports prefill (high-`I`, compute-bound, DSP-saturating) **and** decode (low-`I`, bandwidth-bound, weight-residency-sensitive) **separately**, because no single number describes both — and that is exactly how FlightLLM, EdgeLLM, and TeLLMe report. Fixing the workflow means: (a) a **prefill** test that streams many activation columns against resident weights so each weight-load amortizes over many MACs (compute-bound, the number that shows the fabric's peak GOPS), and (b) a **decode** test that keeps weights resident across tokens so we measure true per-token latency and the bandwidth wall — not the pathological reload.

### I.7 Putting the cost model together

**Technical version.** For a model of `L` layers, hidden `d`, FFN inner `d_ff`, vocabulary `V`:
- **Parameters** ≈ `L · (4d² + 3·d·d_ff) + V·d` (attention QKVO + SwiGLU FFN + embedding/unembedding). TinyLlama-1.1B: ~1.1×10⁹.
- **Prefill FLOPs** ≈ `2 · params · n_prompt` (the factor 2 = one multiply + one add per MAC).
- **Decode FLOPs/token** ≈ `2 · params`.
- **Decode memory/token** ≈ `params · bytes_per_weight + KV_traffic`. With 4-bit weights, `bytes_per_weight = 0.5`.
- **Decode is memory-bound** because `FLOPs/token / bytes/token = 2·params / (0.5·params) = 4` FLOP/byte — far below any modern accelerator's ridge point (tens to hundreds), so you hit the `I·B` roof. **Conclusion: decode speed is set by weight-read bandwidth, full stop.** This is *why* quantization (Part II) — fewer bytes per weight — directly buys decode speed, and why weight-residency on chip is the decode endgame.

---

## Part II — Numbers in hardware

You cannot understand this accelerator without understanding how it represents numbers, because the entire arithmetic core, the quantization pipeline, and two of the three novelties are about *number formats*.

### II.1 Why not just use float like a CPU?

**Plain version.** On a laptop, every number is a 32-bit or 64-bit floating-point value — huge dynamic range, easy to use, but expensive: a 32-bit multiplier is big and power-hungry, and storing billions of 32-bit weights needs gigabytes. On an accelerator we deliberately use *fewer bits*. Fewer bits = smaller multipliers (more of them fit), less memory, less bandwidth, less energy — at the cost of precision. The art is using the *fewest* bits that don't hurt the model's answers. This is **quantization**.

**Technical version.** Hardware multiplier area and energy scale roughly with the *product* of operand bit-widths (an `n×n` multiplier is ~`O(n²)` in area). A 32-bit float multiply is ~16× the area of an 8-bit integer multiply and far more than a 12-bit one. Memory and bandwidth scale linearly with bits/element. So moving from FP32 to 4-bit weights is an ~8× memory/bandwidth win and a large compute-density win. The risk is **quantization error** raising the model's **perplexity** (a measure of how "surprised" the model is — lower is better; Part XVII). The whole quantization literature is about minimizing perplexity loss per bit saved.

### II.2 Fixed point, floating point, and the middle path

**Plain version.** Three ways to store a fractional number in bits:
- **Integer / fixed-point**: just an integer, with an agreed-upon imaginary decimal point. Cheap and exact within its range, but small range (overflows easily).
- **Floating point**: a *mantissa* (the digits) times 2 raised to an *exponent* (the scale). Huge range, but each number carries its own exponent → expensive.
- **Block floating point (BFP)**: the clever compromise ArchBetter uses. A *group* of numbers **shares one exponent**, and each keeps its own small mantissa. You get most of floating point's range at most of fixed point's cost. This is the key idea.

**Technical version.**
- **Fixed-point** `Q(m.f)`: an integer interpreted with `f` fractional bits; value = `int / 2^f`. Multiply is an integer multiply plus a shift. No per-element exponent → dense and fast, but dynamic range is only `2^bits`.
- **Floating-point** IEEE-754: `value = (-1)^s · 1.mantissa · 2^(exp-bias)`. FP32 = 1+8+23; FP16 = 1+5+10; **bfloat16** = 1+8+7 (same range as FP32, less precision — the ML default). Per-element exponent gives enormous range but the adder must align exponents (a barrel shifter per operand) → costly.
- **Block Floating Point (BFP)**: split a vector into blocks of `B` elements; compute one **shared exponent** for the block (typically the max exponent in the block); store each element as a signed integer **mantissa** relative to that shared exponent. A block dot-product becomes: integer-multiply all mantissas, integer-accumulate, then apply the (single, shared) exponent at the end. **You do a whole block of MACs with integer hardware and pay the floating-point cost once per block.** That is why BFP is the format of choice for efficient GEMM engines.

### II.3 BFP12 — ArchBetter's native arithmetic

**Plain version.** ArchBetter's dense math uses **BFP12**: each weight or activation is a 12-bit signed integer (the mantissa), and every group of 16 of them shares one 8-bit exponent. So a 16-element dot product is 16 cheap integer multiply-accumulates, and the shared exponent is applied once. Twelve bits of mantissa is deliberately generous — it's the "insurance margin" so that when 4-bit models from disk are converted up to BFP12 (Part X), the conversion never loses accuracy.

**Technical version.** From `types_pkg.sv`: `BFP12_MANT_W = 12` (signed mantissa, range −2048..+2047), `BFP12_EXP_W = 8` (signed shared exponent), `BFP12_BLK = 16` (elements per block/exponent group). A block dot product `Σ aᵢ·wᵢ` is computed as `(Σ mant(aᵢ)·mant(wᵢ)) · 2^(exp_a + exp_w)`, where the inner sum is a pure signed-integer reduction. The 12×12 signed product needs `bfp12_prod_t` = 24 bits; the running accumulation across the reduction dimension needs headroom against overflow — ArchBetter uses `dense_acc_t` for the per-PE accumulator and a 44-bit `array_acc_t` (`ARRAY_ACC_W = 44`) for the array-level accumulator (enough to sum 128 products of 24-bit values with margin: `log2(128) + 24 = 31` bits minimum, 44 gives 13 bits of overflow insurance and room for residual-add growth, Part I.3). **Runtime-shrinkable**: the mantissa width is configurable down to BFP6 to feed the shred ladder (Part X) — fewer mantissa bits = smaller effective multiply = less energy for "unimportant" weights.

### II.4 The quantization zoo: Q4_K, Q5_K, Q6_K, Q8_0, ternary

**Plain version.** Models are shipped from the internet in compressed formats (the "GGUF" / llama.cpp family). The names encode how many bits per weight and how the scaling works: **Q4_K** = ~4 bits/weight with a clever two-level scale, **Q8_0** = 8 bits/weight with a simple per-block scale, etc. ArchBetter reads these directly from DRAM and **dequantizes** them on the fly into BFP12 as they stream onto the chip — so you can serve a real downloaded model without a separate conversion step. At the extreme, FFN weights can be squeezed all the way down to **ternary** — just −1, 0, +1 — which needs *no multiplier at all* (Part VI).

**Technical version.** k-quant formats use **per-block** and **per-super-block** scales to preserve dynamic range cheaply:
- **Q8_0**: blocks of 32; one FP16 scale `s` per block; weight = `s · int8`. Dequant = sign-extend + multiply (fold `s` into the BFP exponent).
- **Q6_K / Q5_K**: groups of 16/32; FP16 scale + min per group; weight = `s · q + min`. Dequant = unpack nibble → signed, multiply, add min, re-block.
- **Q4_K**: a **super-block** scale plus per-sub-block scales; two-stage dequant.
- **Ternary** `{−1,0,+1}`: 1.58 bits/weight information-theoretically; multiply becomes select/negate (Part VI).
The **block-size discipline** is a hard invariant: the BFP destination block (16) must be `≤` the source quant group (Q6_K=16, Q4_K=32/256, …), otherwise dequant would force a *re-quantization* that collapses dynamic range and leaks perplexity. ArchBetter's `csd_dequant` micro-pipeline in `csd_drain_engine` does this at the URAM fill boundary; the new `quant_fmt_e` enum and `csd_descriptor_t` fields (`quant_fmt`, `group_size`, …) carry the format per transfer. **Validation gate**: a golden Python dequant must bit-match the RTL before a format "ships."

### II.5 Rounding, saturation, and why they matter

**Technical version.** Two hardware policies you must always specify or you will ship a bug:
- **Rounding**: round-to-nearest-even (unbiased; the default for accumulation) vs truncation (biased toward zero; cheaper, used where bias is tolerable). A biased round inside a deep accumulation produces a systematic drift that shows up as perplexity loss.
- **Saturation vs wrap**: on overflow, clamp to max (saturate) or wrap modulo (silent corruption). Accumulators must be wide enough to *never* overflow within a reduction (ArchBetter's 44-bit choice), and any *output* requantization must **saturate**, never wrap. The contract assertions in the testbenches exist partly to catch a wrap that a wrap-vs-saturate mistake would introduce.

---
## Part III — From electrons to a multiply: memristors, ReRAM, 4T2R, compute-in-memory

This is the physics layer. ArchBetter is a **digital twin** of an analog compute-in-memory chip, so you must understand the analog thing it is modeling — both to defend the architecture and to know what the noise hooks (Part X) are for.

### III.1 The von Neumann bottleneck and the CIM idea

**Plain version.** In a normal computer, memory and compute are separate buildings, and you spend most of your time (and energy) hauling data between them — the "**von Neumann bottleneck**." **Compute-in-memory (CIM)**, also called **processing-in-memory** or **in-memory computing**, says: *do the math inside the memory itself*. If your memory cells can multiply and add as a side effect of being read, you never move the weights — they compute where they sit. For neural networks, whose bottleneck is exactly "move billions of weights," this is potentially revolutionary. ArchBetter models a specific kind of CIM cell: a **memristor** crossbar.

**Technical version.** Energy to fetch a 32-bit word from DRAM is ~640 pJ; a 32-bit FP multiply is ~3–4 pJ; an 8-bit integer MAC is well under 1 pJ. So **data movement, not arithmetic, dominates energy** (often >90%). CIM collapses the `fetch → compute` sequence into a single physical operation, attacking the dominant energy term. Analog CIM realizes the **multiply-accumulate via physics** (Ohm's law + Kirchhoff's law, below), achieving extreme energy efficiency (the 4T2R ReRAM macro ArchBetter calibrates against reports 59–95.3 TOPS/W) — but at the cost of analog non-idealities (noise, drift, limited precision) and no system-level glue. ArchBetter's thesis: build the **digital system** (dispatcher, NoC, KV cache, ping-pong, sparse path) that a CIM tile is missing, and model the CIM tile as a calibratable digital twin so the two can later be fused.

### III.2 The memristor and ReRAM

**Plain version.** A **memristor** ("memory resistor") is a device whose electrical resistance you can *set* and that *remembers* it after power off. In **ReRAM** (Resistive RAM), you build it from a thin metal-oxide film (e.g. HfO₂, TaOₓ): apply a voltage and you grow a tiny conductive **filament** of oxygen vacancies through the oxide (low resistance = "1"-ish), apply the opposite voltage and you dissolve it (high resistance = "0"-ish). Crucially, you can set *intermediate* resistances — so one cell can store an analog weight value, not just a bit. That analog conductance *is* the weight.

**Technical version.** A ReRAM cell stores **conductance** `G` (= 1/resistance), programmable between a low-conductance reset state and a high-conductance set state via **SET**/**RESET** voltage pulses that grow/rupture an oxygen-vacancy filament in the oxide. Multi-level cells encode several bits as distinct `G` levels. **Drift** (Part X): the filament's vacancies and metal ions diffuse over time and temperature, so `G` slowly changes — the dominant reliability limit. The relevant device parameters are `V_set`/`V_reset` (programming thresholds), the conductance window `G_on/G_off` ratio, read disturb, endurance (cycles), and retention (drift over time). PCM (phase-change memory) is a cousin with the same drift problem.

### III.3 Ohm's law + Kirchhoff's law = a free multiply-accumulate

**Plain version.** Here's the magic. Put an input as a **voltage** `V` across a memristor whose conductance is the weight `G`. By Ohm's law, the current through it is `I = V·G` — that's a **multiply**, done by physics, instantly, for free. Now wire up a whole *column* of these cells to one wire; by Kirchhoff's current law, the currents all add up on that wire: `I_total = Σ Vᵢ·Gᵢ` — that's a **dot product** (multiply *and* accumulate), done by physics, for the whole column at once. A grid (crossbar) of these does a full matrix-vector multiply in one electrical settling time. *This* is why analog CIM can be so efficient — the GEMM is a law of nature, not a sequence of instructions.

**Technical version.** A crossbar of memristors at conductances `G_{ij}` driven by input voltages `Vᵢ` produces per-column currents `I_j = Σᵢ Vᵢ · G_{ij}` (Ohm + Kirchhoff). This is exactly a matrix-vector product `I = Gᵀ V` evaluated in O(1) settling time with O(N²) devices — analog **spatial** parallelism. The output currents are digitized by per-column **ADCs** (or, in voltage-mode designs, sense amps), which dominate area/energy and limit precision. Challenges: device variability, IR drop along wires, ADC cost, sneak paths, and the need for **differential** encoding to represent signed weights (next).

### III.4 The 4T2R differential cell

**Plain version.** A single memristor can only have *positive* conductance, but neural weights can be negative. The fix: use **two** memristors per weight — one for the positive part, one for the negative — and take the difference. ArchBetter's cell is **4T2R**: 4 transistors + 2 ReRAM devices, arranged as a differential pair. The two devices `G⁺` and `G⁻` sit on the two halves of a balanced sense circuit; the weight is `G⁺ − G⁻`. This differential structure is not just for signs — it's the secret to the AC drift-refresh novelty (Part X), because a signal applied *equally* to both halves cancels out at the difference.

**Technical version.** **4T2R** = 4 transistors, 2 resistive (ReRAM) elements. The two memristors form a differential conductance pair feeding a **differential sense amplifier** at the column bottom. Effective weight `w ∝ (G⁺ − G⁻)`, giving signed weights and **common-mode rejection**: any stimulus applied identically (common-mode) to both legs is rejected by the sense amp (CMRR ≥ 40 dB achievable with matching). The 4 transistors provide access/select and the differential read path. In ArchBetter's twin (`cim_cell_4t2r.sv`) this collapses to a single signed BFP12 mantissa `w_reg` (the modeled `G⁺ − G⁻`), with `noise_rd_in` injection ports standing in for the analog non-idealities and the AC-refresh stimulus.

### III.5 The digital twin — what `cim_cell_4t2r.sv` actually is

**Plain version.** ArchBetter runs on an FPGA, which is *digital* — it has no memristors. So instead of analog cells, it builds an exact **digital model** ("twin") of what the analog 4T2R cell would compute: the weight is a 12-bit number in a register, the input is a 12-bit number, and the multiply is done by a normal digital multiplier (a DSP block). But the twin keeps "injection points" where you can later add the analog imperfections (noise, drift) — so that once you have real silicon measurements, you can calibrate the twin to behave like the real chip. It's a flight simulator for the analog accelerator.

**Technical version.** `cim_cell_4t2r` models the cell's *function* (`i = V·(G⁺−G⁻)` → signed mantissa product `a_in · w_reg`) and its *temporal reduction* (the dot-product accumulation over the K reduction beats) in fixed-point, mapped onto one **DSP48E2** (Part IV). The `ENABLE_NOISE_HOOKS` parameter gates `noise_rd_in`, a per-beat read-noise term folded into the product at the multiply (M) stage; when off (0), it elaborates to constant 0 and prunes, so synthesis infers a clean DSP product. The hooks are where (a) device noise/drift models and (b) the §X AC-refresh stimulus enter. **Key clarity point from the RTL header:** the DSP's accumulation is the **temporal** reduction over K activation beats — *not* the analog crossbar's spatial Kirchhoff column-sum; that spatial sum is modeled separately by the `dense_group` adder tree (Part V). Conflating the two is the most common misreading of this architecture.

---

## Part IV — The Processing Element and the DSP48E2

### IV.1 What a MAC is and why everything is built from it

**Plain version.** The atom of neural-network compute is the **multiply-accumulate (MAC)**: `accumulator += a × b`. A dot product is a pile of MACs; a matrix multiply is a pile of dot products; a neural network is a pile of matrix multiplies. So the entire performance of an accelerator comes down to: *how many MACs can I do per clock cycle, and how busy can I keep them?* A **Processing Element (PE)** is the hardware that does one MAC stream.

**Technical version.** A MAC computes `p ← p + a·b`. Throughput is measured in **MACs/cycle** (× clock frequency = MACs/s; ×2 for FLOPs since a MAC is a multiply + an add). Peak compute `P_max = (number of MAC units) × f_clock × 2` FLOP/s. ArchBetter's dense fabric has 512 physical MAC units (PEs) at 250 MHz → `P_max = 512 × 250e6 × 2 = 256` GFLOP/s (= 256 GOPS) at peak. **Utilization** = achieved MACs/cycle ÷ peak MACs/cycle; your decode test measured 0.11% because the PEs were idle during weight reload (Part XII).

### IV.2 The DSP48E2 — the FPGA's hardened multiplier

**Plain version.** On an FPGA you *could* build a multiplier out of generic logic (LUTs), but it would be slow and huge. So FPGA vendors hard-bake dedicated multiplier blocks into the silicon: on Xilinx UltraScale+ they're called **DSP48E2** slices. Each is a fast 27×18-bit multiplier with an adder and several pipeline registers, purpose-built for MACs. ArchBetter has 1824 of them available and uses 512 (one per dense PE). The sparse core uses **zero** — by design, because ternary "multiply" needs no multiplier (Part VI).

**Technical version.** The **DSP48E2** contains: a 27×18 signed multiplier, a 48-bit accumulator/ALU, a pre-adder, and pipeline registers **A1/A2, B1/B2** (two-deep input regs), **M** (product reg), and **P** (output/accumulator reg). Using its internal registers (rather than fabric flops) is what lets it run at full `f_max` — an unregistered DSP is the classic timing-killer. The methodology checks **DPIP-2/DPOP-3/DPOP-4** literally exist to flag "you didn't use the DSP's pipeline registers." ArchBetter's `(* use_dsp = "yes" *)` hints steer Vivado to pack the whole MAC into one DSP with all stages registered. A 12×12 signed multiply fits comfortably in the 27×18 envelope (with room to grow operand width for the dequant fold-in).

### IV.3 Pipelining — the idea that makes clocks fast

**Plain version.** Suppose a task takes 4 steps. You *could* do all 4 in one long clock cycle — but then your clock must be slow enough for the whole chain, so you do few operations per second. **Pipelining** breaks the task into 4 short stages with a register between each, like an assembly line: each stage does its bit in one fast cycle and hands off. Now your clock runs 4× faster, and once the pipe is full you finish one result *every* cycle. The cost is **latency** (a result takes 4 cycles to fall out the end) and the discipline that *control signals must travel down the pipe in lockstep with the data*. Get that lockstep wrong and you compute garbage — which is exactly the bug we fixed earlier in `tb_cim_cell_4t2r` (the golden model was one pipeline stage too shallow).

**Technical version.** Pipelining inserts registers to shorten the **critical path** (longest combinational delay between flops), raising `f_max = 1/(t_critical + t_setup + t_clk-to-q + skew)`. **Throughput** becomes 1 result/cycle (after fill); **latency** becomes `depth` cycles. The hazards: data must be accompanied by a matched **valid** shift register and any control (e.g. accumulator clear) must be delayed by the same depth. **Initiation Interval (II)** = cycles between new inputs (here II=1, fully pipelined). Deep pipelines hide memory/compute latency but cost registers and add latency to feedback loops (which is why accumulator loops are kept shallow).

### IV.4 ArchBetter's fused MACC — the Phase-8/8b design

**Plain version.** Earlier, ArchBetter did the multiply in one DSP and the running sum in a *second* DSP — two DSPs per PE, 1024 total, and badly pipelined (slow, power-hungry). The **fused MACC** redesign does the entire multiply-and-accumulate in **one** DSP per PE (512 total) by using the DSP's *internal* accumulator register, and it's fully pipelined through all the DSP's built-in registers. A control signal `acc_clr` decides whether the first product of a new dot-product **loads** the accumulator or **adds** to it. This halved the DSP count, cleared the methodology warnings, and freed room to grow.

**Technical version.** The pipeline (`cim_cell_4t2r.sv`, Phase-8b) is **4 stages**: `a_in → A1 → A2 → M → P`.
- **A1/A2** (DSP `AREG=2`/`BREG=2`): two cascaded input registers latch the activation and weight; splitting into both built-in stages clears **DPIP-2** and shortens the operand-to-multiplier setup path (more `f_max`).
- **M**: the signed 12×12 product (+ optional `noise_ext`), the DSP M-register.
- **P**: the accumulator — `p_reg ← acc_clr ? m_reg : p_reg + m_reg` — the DSP P-register doing load-or-accumulate.
Latency contract: **4 cycles** `a_in→p_reg`; `acc_valid` = `a_valid` delayed 4. The enclosing `dense_group` therefore waits **3 drain cycles** (`GEMM_DRAIN_CYCLES=3`) before snapshotting. The fusion eliminated the second DSP (1024→512), cleared DPIP-2/DPOP-3/DPOP-4, and lowered dynamic power. **This is a model lesson in elite FPGA design:** map the algorithm onto the *hardened primitive's* native structure (use its registers, its accumulator) rather than building parallel logic the synthesizer must struggle to pack.

### IV.5 The PE wrapper

**Technical version.** `dense_pe` wraps `cim_cell_4t2r` and adds the snapshot logic — the cell holds the *live* accumulator; the PE captures it when the reduction completes. The PE is the granularity at which weights are scanned in (`w_we`, `w_in`) and the granularity at which the array's logical tiling is expressed. One PE = one DSP = one MAC lane.

---

## Part V — The dense core: groups, systolic arrays, logical vs physical

### V.1 Systolic arrays — the canonical matmul machine

**Plain version.** A **systolic array** is a grid of PEs where data marches through rhythmically, like a heartbeat (the name comes from "systole"). Weights sit in the grid; activations flow in from one side; partial sums accumulate as data passes PE to PE. It's the classic way to do matrix multiply in hardware (Google's TPU is a giant systolic array). The beauty is *locality*: each PE only talks to its neighbors, so there are no long wires and the clock stays fast. The challenge is feeding it: you must deliver the right operand to the right PE at the right cycle, every cycle, or the array starves.

**Technical version.** In a weight-stationary systolic array, each PE holds a weight `W[i][j]`; an activation `x[i]` enters row `i`, is multiplied, and the partial sum propagates down column `j`, accumulating `Σᵢ x[i]·W[i][j] = y[j]`. Data reuse is spatial: each activation is used by a whole row, each partial sum threads a column. **Dataflow taxonomy** (Part XI) names the variants by what stays put: **weight-stationary** (weights resident, activations stream), **output-stationary** (accumulators resident, both operands stream), **row-stationary** (Eyeriss). The array's edges need carefully scheduled feed/drain. ArchBetter is **weight-streaming with output-stationary tile accumulation** — a deliberate hybrid (Part V.4).

### V.2 The reduction problem: spatial vs temporal

**Plain version.** A dot product of length 128 means adding up 128 products. You can add them two ways: **spatially** — have 128 multipliers and a tree of adders combine them in one shot (fast, lots of hardware); or **temporally** — have one multiplier do them one-at-a-time and keep a running sum (slow, little hardware). Real designs mix both: ArchBetter spatially reduces *within* a 16-row group (an adder tree) and temporally accumulates *across* groups/beats (the DSP's accumulator). Understanding which reduction is which is the key to reading this architecture — and it's the thing the RTL comments hammer on.

**Technical version.** For `y[j] = Σ_{i=0}^{127} x[i]·W[i][j]`:
- **Spatial reduction**: the 16 rows of a `dense_group` are summed by a combinational **adder tree** (`log₂16 = 4` levels) → one `group_acc` per cycle. This models the analog crossbar's Kirchhoff column-sum.
- **Temporal reduction**: the per-PE DSP P-register accumulates across the **K reduction beats** (the dot-product's depth dimension) — `Σ_k`.
- **Array-level reduction**: a persistent register-file bank (`array_acc_t[128]`) accumulates partial strips across the **8 logical row-tiles** as the dispatcher walks the grid.
Three reductions, three mechanisms, three locations. The invariant: **partial sums never leave a 16×16 group on the global interconnect** — only fully-reduced 16-wide column outputs cross the array boundary. This keeps interconnect traffic low and is the "single most important invariant" in the spec.

### V.3 Logical vs physical — the time-multiplexing trick

**Plain version.** ArchBetter *acts like* it has a 128×128 grid of multipliers (16,384 of them) — but that would need ~32,000 DSPs, and the chip only has 1,824. Impossible. So it cheats with **time-multiplexing**: it physically builds a small 16×32 grid (512 PEs) and *reuses* it 32 times, walking across the logical 128×128 layer tile by tile. Same total work, 32× fewer multipliers. The "128×128" is a *logical* abstraction the schedule presents; the *physical* hardware is small and busy. Anyone who reads "128×128" as "build 16,384 PEs" has misread the design — and a previous version of the code made exactly that mistake.

**Technical version.** Logical shape: 128×128, partitioned into an **8×4 grid of 16×32 logical tiles** (`DENSE_LOGICAL_TILE_ROWS × DENSE_LOGICAL_TILE_COLS = 8×4`). Physical shape: **two `dense_group` instances** (each 16×16 = 256 PEs) side-by-side → **16×32 = 512-PE physical kernel** = 512 DSP48E2 ≈ 28% of the device. The dispatcher walks the 8×4 = 32 logical tiles in raster order, each reusing the same physical kernel; tile residency latency is hidden under URAM ping-pong fill. A literal spatial array would need ~32k DSPs (each old 2-DSP PE × 16384); the time-multiplex achieves identical logical throughput per layer with 32× less silicon and *exposes the per-tile addressing the Weight Shredding Oracle needs* (Part X). Phase-9 may scale to 4 physical groups now that each PE is 1 DSP — the macro-ISA tile schedule absorbs the scaling with no RTL change outside the array harness.

### V.4 The output-stationary tile accumulator

**Technical version.** For each logical tile `(gr, gc)`: (1) weights for that tile stream from URAM into the PE registers; (2) the activation band for row-group `gr` is broadcast via the NoC; (3) the two physical groups produce a 32-wide partial strip; (4) that strip is added into a **persistent array-level accumulator bank** of 128 `array_acc_t` accumulators indexed by global column, *staying live across all 8 row-tiles*; (5) after the 8 row-tiles of a column-strip are visited, that strip is final; after all 4 column-strips, the full 128-column `y_out` drains and `y_valid` pulses. The accumulator bank is a **register file, not a spatial reduction tree** — it lives outside the group fabric. This output-stationary choice means each weight is loaded once per tile visit and *not* re-fetched per output — but at `K_TILE=1` (decode), the per-tile weight load dominates, which is the throughput finding from Part I.6/XII.

---

## Part VI — The sparse core: ternary weights and table-lookup multiplication

### VI.1 Why a second, different core

**Plain version.** The FFN part of an LLM (two-thirds of the weights) tolerates being squeezed down to ternary values: −1, 0, +1. When a weight is only −1/0/+1, "multiplying" by it is trivial — you either pass the input through, drop it, or flip its sign. No multiplier needed. So ArchBetter has a **second** compute core, the **sparse core**, specialized for ternary FFN math, that uses *zero* DSP blocks and instead uses tiny lookup tables. The dense core (DSPs) and sparse core (lookup tables) run different math at different precisions — a **heterogeneous** design — and the dispatcher overlaps them so neither sits idle.

**Technical version.** Ternary weights `{−1,0,+1}` carry ~1.58 bits of information and turn MACs into sign-select-add. ArchBetter's sparse core implements **TLMM (Table-Lookup Matrix Multiplication)**: precompute, for a tile of activations, the partial sums for all relevant ±/0 weight patterns, store them in **LUTRAM/SRL** primitives, and let the weight pattern index the table to emit the signed sum directly. **Zero DSP** is a hard contract — a DSP in the sparse core is a *bug*, not a trade-off. This is the standard "BitNet/ternary-LLM" hardware trick: replace arithmetic with memory lookup when the operand alphabet is tiny.

### VI.2 How table-lookup multiply works

**Plain version.** Here's the trick. Suppose you have 4 activations `a,b,c,d` and you need to combine them with ternary weights. There are only so many sign patterns. Precompute the answers for the patterns you'll need and store them in a small table. Then, instead of multiplying, you take the weight pattern as an *address* and just *read* the answer. Memory lookup replaces arithmetic. For ternary the tables stay small; if you tried this with full-precision weights the table would be astronomically large — which is why this only works for the tiny ternary alphabet.

**Technical version.** For a tile of `TLMM_TILE = 16` activations, the engine builds sum tables keyed by the ternary weight sub-pattern; the table emits `Σ sign(wₖ)·aₖ` for the selected lanes. Tables live in **distributed RAM (LUTRAM)** / **SRL** (`(* ram_style = "distributed" *)`). The adder tree that combines lanes is tagged `(* use_dsp = "no" *)`. Tile size is a tuning knob: larger tiles explode table depth (exponential in pattern length), smaller tiles kill efficiency (overhead per lookup) — `TLMM_TILE=16` is the chosen balance. Modules: `tlmm_driver` (reads ternary weights + activations from the sparse URAM ping-pong, drives the tile), `sparse_tile` (the lookup + adder fabric), `sparse_out_collector` (drains results to the output URAM/boundary).

### VI.3 Asymmetric pipelining — overlapping the two cores

**Plain version.** The dense core has a deep pipeline (many stages, long latency); the sparse core is shallow (single-cycle lookup). If you ran them one after another, the sparse core would finish fast and then twiddle its thumbs while the dense core grinds. Instead the dispatcher **interleaves** them: it slots the sparse core's quick work into the gaps (bubbles) of the dense core's long pipeline, so wall-clock time is hidden. This is **asymmetric pipelining** — deliberately matching a fast unit's idle time against a slow unit's busy tail.

**Technical version.** The dispatcher issues sub-ops to both cores and interleaves issue slots so the shallow sparse pipeline fills the deep dense pipeline's latency shadow. This is a **latency-hiding** schedule: total time ≈ max(dense_time, sparse_time) rather than their sum, *if* the dependency graph allows overlap (FFN after attention, etc.). It's the same principle as CPU out-of-order execution hiding cache-miss latency behind independent work, but statically scheduled in the macro-ISA (Part IX) rather than discovered at runtime.

---
## Part VII — Memory hierarchy: DRAM, URAM, BRAM, LUTRAM, ping-pong, the CSD engine

Memory is where accelerators are won or lost (recall: decode is memory-bound). You must know the levels, their sizes, their speeds, and the tricks that hide their latency.

### VII.1 The memory pyramid

**Plain version.** Memory comes in a pyramid: tiny+fast at the top, huge+slow at the bottom. On this FPGA, top to bottom: **registers** (flip-flops, single-cycle, a few bits each), **LUTRAM** (small distributed memories built from logic, ~tens of bits), **BRAM** (Block RAM, medium on-chip blocks, ~36 kbit each), **URAM** (UltraRAM, bigger on-chip blocks, ~288 kbit each), and finally **DRAM** (off-chip, gigabytes, but slow and energy-expensive to reach). The whole game is keeping the data you need *now* as high up the pyramid as possible. Billions of weights can only live in DRAM; you stream them up into URAM in chunks as you need them.

**Technical version.** XCKU5P budget: ~216,960 LUTs, ~433,920 FFs, 1,824 DSP48E2, **480 BRAM** (36 kbit each, ~2.1 MB total), **64 URAM** (288 kbit each, ~18.4 Mbit). Off-chip DRAM (DDR4 via a soft MIG controller on the real board) holds the model. Latency/bandwidth roughly: registers 0-cycle; LUTRAM 1-cycle; BRAM 1-2 cycle, dual-port; URAM 1-cycle native read + optional output reg, cascadable; DRAM tens-of-ns latency, bandwidth-limited. **Energy** rises ~order-of-magnitude per level down. ArchBetter's allocation: **weights/activations → URAM**, **KV cache → BRAM**, **TLMM tables → LUTRAM**, **accumulators/pipelines → registers**, **model → DRAM**. This mapping is a first-class architectural decision, not an afterthought.

### VII.2 Why URAM for weights, BRAM for KV

**Technical version.** **URAM288** is 72-bit-wide × 4096-deep, single-clock, with a deep read pipeline and native 8-read/8-write throughput profile — ideal for *streaming* wide weight/activation beats. **BRAM (RAMB36)** is more flexible (configurable aspect ratios, true dual-port, built-in FIFO logic) and better for the *random-access, read-modify-append* pattern of a KV cache. So weights stream from URAM (bandwidth-shaped), KV lives in BRAM (access-shaped). Mixing them would put random KV accesses in the way of burst weight fills. ArchBetter uses **5 URAMs** total: 4 for ping-pong (2 dense + 2 sparse) + 1 for output staging — only 8% of 64, leaving huge headroom for weight pre-staging, KV spill, or multi-layer pipelining.

### VII.3 Ping-pong (double buffering) — hiding fill latency

**Plain version.** If you compute from a buffer while it's still being filled from DRAM, you get garbage (or you stall waiting). The fix is **ping-pong** (double buffering): use *two* buffers. While the compute core chews on buffer A, the memory system fills buffer B from DRAM in the background. When A is done and B is ready, *swap*: compute on B, fill A. Done right, the compute core never waits for memory — the fill is completely hidden behind compute. This is the single most important latency-hiding trick in streaming accelerators.

**Technical version.** ArchBetter has **4 ping-pong banks**: dense uses banks 0/1 (compute/fill pair), sparse uses 2/3. The dispatcher issues `OP_PINGPONG` to swap compute-side and fill-side after a **drain handshake** with the consuming core (so no read is in flight across the swap). The `pingpong_if` interface carries the swap request/done and the active-side select. The cascade adapter stitches the native 72-bit URAM into the 144-bit cascaded word the streamers consume. **Double buffering converts a `fill_time + compute_time` serial cost into `max(fill_time, compute_time)`** — the same algebra as asymmetric pipelining (Part VI.3), applied to memory.

### VII.4 The CSD engine — decompress-on-the-fly fill

**Plain version.** DRAM bandwidth is precious, so you don't want to waste it shipping uncompressed weights. The **CSD (Compressed Sparse Dense) engine** fetches *compressed* weights from DRAM and **decompresses them on the way in** to URAM — so the DRAM bus only ever carries the small compressed form, and the on-chip side sees ready-to-use weights. In ArchBetter this engine also does the **quantization conversion** (Q4_K/Q5_K/… → BFP12, Part II.4) at the same boundary, for free, hidden under the fill. One pipeline, two jobs: decompress and dequantize.

**Technical version.** `csd_engine` / `csd_drain_engine` handle DRAM↔URAM background transfers. The `csd_dequant` micro-pipeline performs per-format dequant (sign-extend, scale fold-in via LUT-based shift-and-add — *not* DSPs, to keep DSPs for the dense core) as blocks land. The `csd_descriptor_t` carries `quant_fmt`, `group_size`, `scale_stride`, `zero_point_stride`. Because dequant happens *inside the existing fill path*, it adds no extra read port and no extra latency — it's hidden under the ping-pong fill the compute core is overlapping anyway. This is why §2.7 calls the fill boundary "the dequant boundary": it's the one place where format conversion is latency-free.

### VII.5 Activation outliers — the SmoothQuant problem

**Technical version.** Llama-class activations have **channel outliers**: a few channels with values 10-100× the rest. Block them naively and one outlier blows out the shared BFP exponent for its whole block (Part II.3), crushing the precision of the other 15 elements. Two stacked mitigations: (1) **SmoothQuant-style channel rotation** — migrate the outlier magnitude from activations into weights offline, absorbed into the static layer descriptor (free at runtime); (2) **per-strip activation BFP grouping at the NoC drop** — each 16-wide activation strip broadcast over the NoC becomes its own BFP group, so an outlier only contaminates its own strip. This is a real, named failure mode of low-bit LLM inference; knowing it marks you as someone who has actually deployed quantized models.

---

## Part VIII — Interconnect: the NoC

### VIII.1 What a Network-on-Chip is

**Plain version.** When you have many blocks on a chip that need to send data to each other, you need an on-chip "road network" — a **Network-on-Chip (NoC)**. Like a city's roads, it has routers (intersections) and links (streets). The question is how traffic is managed. Two philosophies: **packet-switched** (every message is a packet with an address; routers decide where it goes at each hop, like the internet — flexible but adds latency and buffering) and **circuit-switched** (you set up a dedicated path in advance, like an old phone call; once connected, data flows with zero per-message decision — fast and predictable, but you pre-commit the path). ArchBetter uses **circuit-switched**, because its dataflow is known ahead of time.

**Technical version.** A **packet-switched NoC** (mesh/torus, virtual channels, credit-based flow control, routing tables) maximizes flexibility but pays per-flit arbitration latency and buffer area — overkill when the traffic pattern is static. A **circuit-switched NoC** configures physical paths *before* execution; routers degenerate to pure muxes (no runtime arbitration, no transaction layer). ArchBetter's dispatcher hard-configures paths with `OP_CFG_NOC` *before* a layer runs (configuration-before-execution); once committed (`OP_COMMIT_NOC`), `noc_router` instances are muxes. This is the "Blackwell B200 style" referenced in the spec: for a known dataflow, circuit switching wins on latency, energy, and predictability.

### VIII.2 The streaming protocol — and why "no AXI"

**Plain version.** Blocks need a handshake so a sender knows the receiver is ready. The industry-standard handshake is **AXI** (from ARM) — powerful, but heavy: it has separate address/data/response channels, burst logic, ordering rules, lots of overhead. Inside a tight accelerator fabric, that overhead is wasted. So ArchBetter uses a **lean** handshake: just `data`, `valid` (sender says "data is good"), `ready` (receiver says "I can take it"), and `last` (marks the end of a burst). A transfer happens only when `valid AND ready` are both high in the same cycle. Simple, fast, cheap. Using AXI inside the fabric is a design-review *block* here.

**Technical version.** The NoC contract is `data / valid / ready / last (+ user)` — essentially **AXI-Stream's payload semantics without the protocol machinery** (no AXI-Lite register maps, no AXI4 address/burst/ID/response channels). A beat transfers iff `valid && ready` (the universal **valid/ready handshake**; the `strm_if`/`dense2sparse_if` interfaces carry it). **Backpressure** = receiver deasserts `ready` to stall the sender; the sender must *hold* `data`/`valid` stable until accepted (the "hold-on-backpressure" invariant). **Multicast** uses a destination **bitmask** (`noc_mask_t`); a multicast beat is accepted only when *all* selected destinations are ready (unless an explicit skid stage decouples them). Handshake assertions (`assert property`, guarded by `` `ifndef SYNTHESIS ``) live in the interface files and catch protocol violations in sim. The lesson: **match protocol weight to the job** — AXI for SoC peripherals and DRAM, lean streaming for the compute fabric.

### VIII.3 FIFOs, skid buffers, and clock-domain crossing

**Technical version.** A **FIFO** (first-in-first-out queue) decouples a producer and consumer that run at different rates; ArchBetter's `dense2sparse_fifo` (an `xpm_fifo`) buffers dense-core outputs feeding the sparse FFN. A **skid buffer** is a depth-1/2 FIFO that breaks a combinational `ready` path to ease timing while preserving throughput. **Clock-domain crossing (CDC)**: when two clocks differ (e.g. a compute clock and a DRAM/memory clock), a signal sampled by the wrong clock can go **metastable** (settle to an undefined value). The only safe crossings are vendor **XPM** macros (`xpm_cdc_single`, `xpm_cdc_handshake`, `xpm_fifo_async`) or proper two-flop synchronizers with `ASYNC_REG` — never ad-hoc logic. `report_cdc` audits this; the OOC CDC "critical" you saw earlier was a *false* CDC (undefined input-port clock under OOC), not a real metastability path.

---

## Part IX — The control plane: the macro-ISA and the dispatcher

### IX.1 Why an instruction set for an accelerator

**Plain version.** A fixed-function accelerator that can only do one thing is brittle. To run different models and layer shapes, you want it *programmable* — but not with a full CPU instruction set (too fine-grained, too much overhead). The sweet spot is a small set of **macro-instructions**: each one is a coarse command like "load these weights," "do this whole GEMM tile," "configure this NoC path," "write the KV cache." A compact program of these macros drives the whole chip. The **dispatcher** is the block that reads this program and fans each macro out to the right sub-unit. It's the conductor of the orchestra.

**Technical version.** The **macro-ISA** uses 64-bit instruction words (`macro_instr_t`, `MACRO_WORD_W=64`) stored in an on-chip instruction memory (IMEM). Each carries an **opcode** (`macro_opc_e`), a tile/path id, and an immediate payload. The dispatcher decodes and issues sub-ops to four targets: **Memory Manager**, **Dense Core**, **Sparse Core**, **NoC**. This is the **CISC-for-accelerators** pattern (FlightLLM-style): a single macro expands to many cycles of fixed micro-behavior, amortizing instruction-fetch overhead across a large compute payload. Representative opcodes: `OP_LD_W_URAM`, `OP_PINGPONG`, `OP_CFG_NOC`/`OP_COMMIT_NOC`/`OP_BARRIER`, `OP_GEMM_ALL`/`OP_GEMM_LAYER`, `OP_FFN_TLMM`, `OP_KV_WRITE`/`OP_KV_READ`, `OP_ST_OUT`, `OP_SHRED_SWEEP`, `OP_REFRESH_TICK`, `OP_EOP`.

### IX.2 Configuration before execution

**Plain version.** ArchBetter never makes routing or buffer decisions *while data is flowing* — that would add per-beat overhead and unpredictability. Instead, the dispatcher does all setup *first*: commit the NoC paths, choose the ping-pong banks, latch the tile counts — and only *then* let data stream. It's like a factory setting up the assembly line completely before turning on the conveyor belt, rather than re-tooling mid-run. This makes the data path simple and fast (pure muxes, no decisions) at the cost of an upfront config phase.

**Technical version.** The dispatcher issues `OP_CFG_NOC` (path setup) → `OP_COMMIT_NOC` (latch) → `OP_BARRIER` (ensure quiescence) *before* any `OP_GEMM_*`. Banks are selected pre-stream; tile counts latched. The result: the per-beat data path has **no arbitration, no routing-table walk, no dynamic decisions** — deterministic latency, which is what makes the performance model (Part XII) clean and the timing closure (Part XIV) tractable. The cost is a serial config preamble, which amortizes well for large layers and poorly for tiny ones (part of why your toy test's overhead looked huge).

### IX.3 The tile walker — orchestrating a full layer

**Technical version.** In the closed top (`archbetter_core`), a single `OP_GEMM_LAYER` macro makes the dispatcher's **tile-walker** sequence the entire `ROW_CNT × COL_CNT` grid: for each logical tile it drives `WLOAD` (weight streamer scans weights into the PE array, `sched.load_busy=1`) then `GEMM_ACC` (activation streamer streams the band, PEs accumulate), advancing `tile_gr/tile_gc/tile_first/tile_last` on the `dense_sched_if`. The single dense URAM read port is **muxed** between the weight streamer (during WLOAD) and the activation streamer (during GEMM) — temporally exclusive by construction. This is the mechanism whose per-tile `WLOAD` cost dominated your `K_TILE=1` measurement: each tile pays a full 512-weight scan for one beat of compute. The fix (prefill: large K; decode: resident weights) targets exactly this walker behavior.

### IX.4 Barriers, handshakes, and program completion

**Technical version.** `OP_BARRIER` enforces ordering (e.g. GEMM must drain before FFN consumes its output); the dispatcher waits for the relevant `done` handshakes before advancing. `program_done` pulses at `OP_EOP`. Every inter-block boundary uses a `valid/ready` or `req/done` handshake, never a fixed-delay assumption — so the design is *latency-insensitive*: if a sub-unit takes longer (e.g. DRAM stalls), the handshake stretches and correctness holds. Latency-insensitive design is what lets you change a module's pipeline depth (as the fused-MACC did) without breaking the system, as long as the handshake contract is kept.

---

## Part X — The three novelties (the best-paper contributions)

These are what make ArchBetter a research contribution rather than a competent reimplementation. Understand them deeply — they are the spine of the paper.

### X.1 Weight Shredding Oracle — perplexity-aware memory reclamation

**Plain version.** A served LLM uses most of its weights rarely. Caching *which tokens* to keep (KV eviction) is well studied; deciding *which weights to keep at full precision* is not. The **Weight Shredding Oracle** tracks how often each block of weights is actually used, and **demotes** rarely-used blocks to lower precision (12-bit → 8-bit → 6-bit → ternary → deleted), freeing memory and energy. To avoid hurting accuracy, a safety net (the "promote-on-error" path) watches for quality loss and **promotes** a block back up if demoting it caused error. It's adaptive precision: spend bits where they matter, reclaim them where they don't — an idea no competing edge-LLM accelerator has.

**Technical version.** Each 16×16 weight tile carries a 12-bit **Morris-style approximate counter** `u` updated per access as `u ← u − (u>>k) + ACCESS_PULSE` — a **stochastic EWMA** (exponentially-weighted moving average): the shift makes decay multiplicative, the pulse makes recency dominate, all O(1) per access with no random-access BRAM thrash. Every `SHRED_EPOCH` tokens, the `shred_controller` sweeps the counter table (sequential, cache-friendly) and assigns a precision class via thresholds `T_keep/T_dim/T_pen/T_zero` → {BFP12, BFP8, BFP6, ternary→TLMM, zeroed}. **Demotion is free**: it happens during the URAM ping-pong fill (the shred class rides alongside the descriptor and sets the on-load mantissa width — no extra port, no extra latency). **Promote-on-error**: a periodic high-precision shadow computation on a sampled fraction of tiles compares BFPN vs BFP12; residual `> T_residual` increments a demerit counter and triggers promotion — the **perplexity insurance policy**. *Why EWMA, not a min-heap*: the user's first instinct was a heap (O(log N) per access, random BRAM pattern that fights burst URAM fill); EWMA + periodic sweep is O(1) per access and sequential on sweep — primitive-friendly and well-grounded (Flajolet 1985 approximate counting; modern OS page replacement uses the same trick). **Contract assertions**: a flagged tile must reach BFP12 within one epoch; a zeroized tile requested non-zero is a `$error`.

### X.2 AC-Assisted In-Situ Drift Refresh — compute-during-refresh

**Plain version.** Memristor weights **drift** over time (Part III.2) — the stored conductance wanders, corrupting the model. Normally you'd pause and rewrite them (halt-and-refresh), costing throughput. ArchBetter's idea: apply a gentle **AC (oscillating) stimulus** that keeps the memristors healthy *while they're computing*, by exploiting the 4T2R differential cell. Because the cell takes a *difference* of two devices, a stimulus applied *equally* to both is invisible to the read (it cancels as "common mode") — so refresh and compute happen at the same time, with ~zero throughput cost. The architectural novelty isn't the device physics; it's that the differential topology lets refresh hide inside compute.

**Technical version.** A small AC stimulus (frequency, amplitude **TBD-pending-SPICE-simulation**; target: amplitude ≪ `V_set/2`, frequency above the dielectric relaxation knee) is applied **balanced** on both legs of the 4T2R pair via a low-resolution DAC. Physically, the AC maintains electrochemical equilibrium of vacancies/ions and provides activation energy for **defect annealing** (vacancy recombination) — the literature-supported mechanism (the earlier "Soret tractor beam" framing had a sign error: the Soret coefficient is thermophobic for most metal-ion-in-oxide systems). Architecturally: a balanced AC is **common-mode** to the differential sense amp, rejected at ≥40 dB CMRR, so the read proceeds *during* compute — **refresh-during-compute, throughput cost ≈ 0**. The `drift_refresh_controller` drives the pattern into `cim_cell_4t2r`'s noise-hook ports; `OP_REFRESH_TICK` fires it at fixed cadence. **Discipline rule (non-negotiable):** the µW power / frequency / amplitude numbers stay **TBD** until the noise-hook simulation produces them — no training-data guesses enter the paper. The SoC paper cites a separate device-physics letter for the mechanism; do not conflate the two contributions.

### X.3 qN → BFP12 dequant at the URAM fill boundary

**Plain version.** Covered mechanically in Parts II.4 and VII.4 — but as a *contribution* it matters because it lets ArchBetter serve **real downloaded models** (Q4_K/Q5_K/Q6_K/Q8_0 Llama/TinyLlama) directly, converting them to BFP12 on-chip with **no accuracy loss**, the conversion hidden under existing latency. The 12-bit BFP mantissa is deliberately wider than needed as an *insurance margin* against per-tile re-quantization rounding. The novelty is the co-design: the format conversion lives exactly at the one boundary (the fill) where it's free.

**Technical version.** See VII.4. The contribution is (a) the **block-size invariant** (`BFP_dest_block ≤ source_quant_group`) that guarantees no dynamic-range collapse, enforced at elaboration; (b) the **golden-vs-RTL bitmatch validation gate** before any format ships; (c) folding dequant into the CSD drain so it costs no extra read port or latency. Together these make "serve a real GGUF model with zero perplexity degradation" a *verified* claim, not an aspiration.

---
## Part XI — Mapping an LLM onto the silicon

### XI.1 The mapping problem

**Plain version.** You have a math description (a Transformer layer: multiply this 2048×2048 matrix by that vector). You have hardware (a 16×32 physical PE grid, some memories, a NoC). **Mapping** is deciding *which piece of the math runs on which hardware at which time* — how to chop the big matrices into tiles that fit, what order to process them, where to keep each operand, when to fetch the next chunk. A good mapping keeps the multipliers busy and the data close; a bad mapping starves the multipliers. This is the single most intellectually rich part of accelerator design, and it's where most of the real performance comes from.

**Technical version.** Mapping = choosing a **loop nest** ordering and **tiling** of the GEMM, plus a **dataflow** (which operand is stationary), to maximize data reuse and minimize memory traffic subject to on-chip capacity. For `Y[m,n] = Σ_k A[m,k]·W[k,n]`, you tile `m,n,k` into on-chip-sized blocks and choose loop order. The objective is to maximize **reuse** (each fetched byte feeds many MACs) → maximize arithmetic intensity → climb the roofline. Tools like Timeloop/MAESTRO formalize this as a design-space search; ArchBetter fixes a specific mapping in the dispatcher's tile schedule.

### XI.2 ArchBetter's concrete mapping

**Technical version.** A 128×128 logical layer → 8×4 logical tiles of 16×32 → time-multiplexed onto the 16×32 physical kernel (Part V.3). The dataflow is **weight-streaming, output-stationary**: per tile `(gr,gc)`, weights stream into PE registers (resident for that tile's compute), the activation band for row-group `gr` broadcasts via NoC multicast, and partial strips accumulate into the persistent 128-wide `array_acc` bank across the 8 `gr` row-tiles. The reduction dimension `K` is split into 16-row groups (spatial) × beats (temporal) × row-tiles (array bank). **The mapping decision that bites you in decode:** weights are re-streamed per tile visit. For prefill (many activation columns share the same resident weights) this amortizes beautifully; for decode (one column, `K_TILE=1`) it does not — hence the resident-weight decode-mode work item.

### XI.3 Dataflow taxonomy (the vocabulary you must own)

**Technical version.** Named by what stays stationary on-chip to maximize its reuse:
- **Weight-stationary (WS):** weights pinned in PEs; activations stream. Best when weights reused across many activations (prefill, large batch). TPU-like.
- **Output-stationary (OS):** accumulators pinned; both operands stream. Best when reduction is long and you want to avoid partial-sum movement. ArchBetter's array bank is OS.
- **Input/activation-stationary (IS):** activations pinned; weights stream. Best for decode-style reuse of one activation across all weights.
- **Row-stationary (RS):** Eyeriss's hybrid, maximizing reuse of all three (weights, activations, partial sums) via 1-D convolution primitives.
- **No-local-reuse (NLR):** everything streams from a global buffer; simple, bandwidth-hungry.
ArchBetter is a **WS-streaming / OS-accumulation hybrid**. Knowing these names and their reuse trade-offs is table-stakes at an architecture review.

### XI.4 Operator fusion and the non-GEMM ops

**Technical version.** Between the GEMMs sit RMSNorm, SiLU/softmax, residual adds, RoPE (rotary position embedding) — **non-GEMM** ops that are cheap in FLOPs but are *serial dependencies* that can stall a GEMM engine. **Operator fusion** keeps their intermediate results on-chip (no DRAM round-trip) and overlaps them with adjacent GEMMs. Softmax in attention is the nastiest: it needs a max-reduce, an exp, and a sum-reduce across the whole row before `AV` can proceed (FlashAttention's online-softmax trick tiles this to avoid materializing the `n×n` score matrix). ArchBetter handles these in post-processing paths and the dispatcher's schedule; for the paper, *measuring the non-GEMM overhead honestly* matters because it's where naive designs lose to FlightLLM.

---

## Part XII — Performance modeling: latency, throughput, the roofline

### XII.1 The two numbers users feel: latency and throughput

**Plain version.** **Latency** = how long one thing takes (e.g. time to produce one token). **Throughput** = how many things per second (e.g. tokens/second). They are *not* reciprocals when there's pipelining or batching: a pipeline can have high latency (deep) yet high throughput (one result/cycle once full). For an LLM chat experience, users feel two latencies — **TTFT** (time to first token, set by prefill) and **inter-token latency** (set by decode) — and one throughput (decode tokens/s). A good accelerator optimizes all three.

**Technical version.** `Latency = pipeline_depth/f + queueing + memory_stalls`. `Throughput = 1/II × f` for a pipelined unit (II = initiation interval). **TTFT** = dispatch-start → first `y_valid` (your STAGE-5 "first-token latency" counter). **Decode rate** = `f / cycles_per_token` (your "steady per-pass cycles"). **Little's Law** (`L = λW`) relates occupancy, rate, and latency in the buffered/queued parts. Report *all* of: TTFT, prefill tok/s, decode tok/s, and per-op latency — a single number hides the phase that's actually limiting.

### XII.2 GOPS, TOPS, and the utilization trap

**Plain version.** **GOPS** = billion operations per second; **TOPS** = trillion. Peak GOPS is easy: count your multipliers × clock × 2. *Achieved* GOPS is what matters, and it's usually a fraction of peak because the multipliers aren't always busy — that fraction is **utilization**. A chip with huge peak GOPS but 5% utilization loses to a smaller chip at 80%. ArchBetter's peak is 256 GOPS (512 MACs × 250 MHz × 2); your decode test achieved 0.28 GOPS = 0.11% utilization — not because the fabric is slow, but because it was reloading weights instead of computing. **Always report achieved, and always report utilization** — a peak-only number is a red flag reviewers pounce on.

**Technical version.** `GOPS_peak = N_mac × f × 2 / 1e9`. `GOPS_achieved = (total MACs × 2) / (total seconds) / 1e9`. `Utilization = GOPS_achieved / GOPS_peak = MAC/cycle_achieved / N_mac`. Your STAGE-5 instrumentation computes exactly this: `MACS_PER_PASS / steady_per_pass_cycles / 512`. The gap to 100% has named causes: **fill/drain bubbles**, **weight-reload stalls** (your dominant term), **load imbalance**, **non-GEMM serial sections** (Amdahl), and **memory-bound regions** (roofline). Diagnosing *which* is the art; your 0.11% is almost entirely weight-reload stall, provable because cycles-per-tile ≈ the weight-scan length.

### XII.3 The roofline, applied to ArchBetter

**Technical version.** Plot achievable GOPS vs arithmetic intensity. ArchBetter's ridge point `I* = P_max/B`. **Prefill** (`I ∝ n_prompt`, large) sits on the flat compute roof → target near-256 GOPS, near-100% DSP utilization → *this* is the number that proves the fabric. **Decode** (`I≈1..4`) sits on the sloped memory roof → throughput = `I × B`, set by URAM/DRAM weight-read bandwidth, *not* DSP count → here the win comes from quantization (fewer bytes/weight) and weight residency, not more MACs. **The benchmark must place ArchBetter at both points** and report each against the roof. A design that only measures one phase is measuring half the machine — and conveniently hiding the half it's worse at.

### XII.4 Amdahl, Gustafson, and why the serial bits dominate

**Technical version.** **Amdahl's Law**: speedup `S = 1/((1-p) + p/s)` — if a fraction `(1-p)` is serial, accelerating the parallel part `p` by `s` saturates at `1/(1-p)`. For LLM accelerators the "serial part" is the non-GEMM ops + config preamble + fill latency; if those are 10% of runtime, you cap at 10× no matter how fast the GEMM core is. This is why config-before-execution (Part IX.2), operator fusion (Part XI.4), and latency hiding (ping-pong, asymmetric pipelining) matter so much: they shrink `(1-p)`. **Gustafson's** counterpoint: bigger problems (longer sequences, bigger batches) have proportionally more parallel work, so the serial fraction shrinks with scale — which is why prefill at long context looks great and tiny toy tests (your 4×2 sub-layer) look terrible. *Your 0.11% is partly Amdahl on a tiny problem; a real layer amortizes the fixed costs.*

---

## Part XIII — Power and energy

### XIII.1 Dynamic vs static power

**Plain version.** A chip burns power two ways. **Dynamic power** is the cost of *switching* — every time a transistor flips 0→1→0, it charges and discharges tiny capacitors, and that costs energy proportional to how often it switches and how fast the clock runs. **Static power** (leakage) is the cost of just being powered on — current trickles through transistors even when idle. Dynamic power is "work being done"; static power is "the lights are on." On the FPGA report you saw, of 1.308 W total, ~0.835 W was dynamic and ~0.473 W static. Reducing dynamic power means switching fewer things less often (clock gating, lower activity, fewer bits); reducing static means a smaller/cooler design.

**Technical version.** Dynamic: `P_dyn = α · C · V² · f`, where `α` = **activity factor** (average switching probability per node per cycle), `C` = switched capacitance, `V` = supply voltage, `f` = clock frequency. The `V²` term is why voltage scaling is the biggest lever (and why near-threshold computing exists). Static: `P_leak ∝ device count × leakage current(V, temperature)` — rises with temperature (thermal runaway risk). On UltraScale+ at 0.9 V Vccint, your report shows Vccint dynamic 0.927 A dominating. **Energy** `E = P·t = E_op × N_ops`; for accelerators the figure of merit is `E_op` (energy/operation) and its inverse **TOPS/W** (ops per second per watt = ops per joule). The analog 4T2R macro's 59–95.3 TOPS/W is a `E_op` claim; ArchBetter's FPGA digital twin will be far below that (FPGAs are ~100× less efficient than custom silicon) — which is exactly why §0 forbids claiming TOPS/W parity with the analog macro.

### XIII.2 Why activity factor is everything — and where SAIF comes in

**Plain version.** The `α` (activity factor) in the dynamic-power formula is *how often each wire toggles*, and that depends entirely on **what data you run**. The power tool can't know your workload, so it either *guesses* (assumes a default toggle rate everywhere — "vectorless") or you *tell it* by running a real simulation and recording every wire's actual toggling into a file called a **SAIF**. A vectorless number is a guess; a SAIF-annotated number is a measurement. This is the whole reason your power number isn't publishable yet: it was vectorless (a guess), and when we did add a SAIF, a path-naming bug meant only 5% of wires got real activity — so 95% was still guessed.

**Technical version.** **SAIF** (Switching Activity Interchange Format) records per-net **toggle count** (`TC`) and **static probability** (`T0/T1` — fraction of time high) over a simulation window. `read_saif` annotates these onto the routed netlist; `report_power` then computes `P_dyn` with *real* `α` instead of defaults. **Confidence tiers**: vectorless (Low) → RTL/behavioral-sim SAIF (Medium-High, name-mapped, partial coverage) → **post-route timing-sim SAIF** (High, near-100% coverage — the gold standard, from a funcsim netlist + SDF back-annotation). **The two failure modes you must avoid**: (1) low **net-match rate** (your 5% — caused by `read_saif` not stripping the `tb/dut` hierarchy prefix; fixed with `-strip_path`), and (2) **non-representative stimulus** (a SAIF over a toy/idle workload under-reports — your K=1 decode test barely toggles the DSPs, so even a 100%-matched SAIF over it would under-state real compute power). A defensible number needs *both* high match-rate *and* a representative (prefill-saturating + decode) workload.

### XIII.3 Energy per token — the metric that actually matters for edge

**Technical version.** For edge deployment the headline is often **energy per generated token** (joules/token, or its inverse tokens/joule): `E_token = P_total / decode_rate`. This folds compute *and* memory *and* static power into one number a product team cares about (battery life). It is also where quantization and weight-shredding pay off twice: fewer bits → less memory-read energy (dominant in decode) *and* smaller switching in the datapath. Report `E_token` alongside TOPS/W; for the edge-LLM cohort it is frequently the deciding axis. ArchBetter's path to a real `E_token`: representative-workload SAIF (Part XIII.2) → vectored `report_power` → divide by the STAGE-5 decode rate → state the I/O/DRAM boundary explicitly (accelerator-core vs full-system).

### XIII.4 Thermal and the TJA/junction-temperature line

**Technical version.** The power report's `Effective TJA (C/W)` (thermal resistance junction-to-ambient) and `Junction Temperature` close the loop: `T_j = T_ambient + P_total · θ_JA`. Static leakage rises with `T_j`, which raises `P_total`, which raises `T_j` — the **thermal feedback** that, unchecked, is thermal runaway. Edge devices with limited cooling (high `θ_JA`) are power-capped by this loop, not by the silicon's peak. It's why a "1.3 W" number is only meaningful with its thermal context (your report assumed medium heatsink, 250 LFM airflow, 25 °C ambient).

---
## Part XIV — FPGA implementation: synthesis → place → route → timing

### XIV.1 What an FPGA is and why we prototype on one

**Plain version.** An **FPGA** (Field-Programmable Gate Array) is a chip full of generic, reconfigurable logic — a sea of small lookup tables, flip-flops, hardened multipliers (DSPs), and memory blocks (BRAM/URAM) connected by programmable wires. You "program" it by describing your circuit in a hardware language; a tool compiles that into a configuration that wires the generic resources into *your* design. It's not as fast or efficient as a custom-built (ASIC) chip, but you can change it in minutes instead of months and at no per-unit fab cost. ArchBetter prototypes on an FPGA to *prove the architecture works on real silicon* before anyone commits to a (hugely expensive) custom analog-CIM chip.

**Technical version.** An FPGA exposes **CLBs** (configurable logic blocks: LUTs + FFs + carry chains), hardened **DSP48E2** slices, **BRAM/URAM** columns, **clock buffers** (BUFG) and **clock managers** (MMCM/PLL), and **I/O banks**, all stitched by a programmable routing fabric. Your RTL is compiled (synthesized → placed → routed) into a **bitstream** that configures every LUT truth-table, every routing switch, every block mode. FPGA vs ASIC trade-off: ~3-10× slower clock, ~10-20× more area, ~10-100× more energy than the same design in an ASIC — but instant turnaround and no NRE (non-recurring engineering / mask) cost. The XCKU5P here is an **edge-class Kintex UltraScale+**; the validation board will be a **VU9P** (datacenter-class Virtex, hardware-validation only — never the headline number, per CLAUDE.md §11).

### XIV.2 The RTL abstraction and the languages

**Plain version.** You don't draw transistors; you describe behavior at the **Register-Transfer Level (RTL)** — "on each clock edge, this register takes this value" — in a language like **SystemVerilog**. The key mental shift from software: this is not a *program that runs*, it's a *description of hardware that all exists at once*. Every line you write becomes physical gates that operate in parallel, every clock, forever. A `for` loop doesn't loop in time — it *replicates hardware* in space.

**Technical version.** ArchBetter uses **SystemVerilog (IEEE 1800-2017)**. Core idioms (from CLAUDE.md §6): combinational logic → `always_comb` (every output assigned on every path → no latches); sequential → `always_ff @(posedge clk)` with **synchronous active-low reset** (`rst_n`, because UltraScale+ FFs prefer sync reset); `unique case` with mandatory `default`; `logic` typed signals only; explicit `signed` types from `types_pkg`; interfaces with `modport` for every module boundary; `(* use_dsp *)`/`(* ram_style *)` attributes to steer primitive inference; assertions guarded by `` `ifndef SYNTHESIS ``. **Why these rules matter:** each one closes a class of synthesis surprise (inferred latch, multi-driver, unintended LUTRAM, metastable CDC) that would otherwise show up as a methodology warning or, worse, a silicon bug.

### XIV.3 The flow: synthesis, placement, routing

**Plain version.** Compiling RTL to a working chip has three big stages. **Synthesis**: translate your behavioral description into a netlist of actual primitives (LUTs, FFs, DSPs) — like compiling source code to assembly. **Placement**: decide *where on the chip* each primitive physically sits — like assigning seats. **Routing**: connect them with the programmable wires — like running cables between seats. After each stage the tool checks **timing** (does every signal arrive before its deadline?). If not, you have a "timing violation" and must fix it. Only when everything fits, connects, and meets timing do you get a working **bitstream**.

**Technical version.** `synth_design` → technology-mapped netlist (LUT/FF/DSP/BRAM inference, retiming, DSP packing). `opt_design` → logic optimization. `place_design` → assigns sites (congestion-aware). `phys_opt_design` → physical optimization (replication, retiming for timing). `route_design` → realizes nets on the switch fabric. Each step is gated by **Static Timing Analysis (STA)**. Quality gates (CLAUDE.md §5): zero critical `synth_design` warnings; zero `report_methodology -checks {all}`; empty `report_drc` at route; ≥10% WNS slack target; `report_cdc` clean. The order is non-negotiable — *sim-clean before synth, synth-clean before impl* — because methodology debt compounds.

### XIV.4 Static Timing Analysis, slack, and WNS — the deadline math

**Plain version.** Every signal that travels between two flip-flops has a deadline: it must arrive and settle before the next clock edge captures it. **Slack** = deadline − actual arrival. Positive slack = made it with time to spare; negative slack = missed the deadline = the chip will compute wrong values at that clock speed. The **Worst Negative Slack (WNS)** is the tightest path in the whole design — your margin of safety. ArchBetter's WNS is +0.057 ns at 250 MHz: it *passes*, but with only 1.4% of the clock period to spare — thin. And that's on an idealized clock; a real clock tree (which has its own delays) could eat that margin. This is why timing closure with *headroom* (the §8 goal of ≥10%) matters: thin margins break when reality is added.

**Technical version.** For a register-to-register path: `slack = T_clk − (T_clk-to-q + T_logic + T_routing + T_setup − T_skew)`. **Setup** (max-delay) checks data arrives before the capture edge; **hold** (min-delay) checks data doesn't arrive *too soon* (race-through). **WNS/TNS** (worst/total negative slack) for setup; **WHS/THS** for hold. ArchBetter: WNS +0.057, TNS 0.000 (no setup violations), WHS +0.040 (hold met) @ 250 MHz / 4.0 ns. The critical path runs **NoC router → dense-array DSP**. Closing with headroom means pipelining that path or trimming logic levels. **OOC caveat:** with no `HD.CLK_SRC`, the clock-tree insertion delay/skew isn't modeled, so this WNS is *optimistic*; the non-OOC wrapper (Part XVI) will give the true number — and may require dropping to e.g. 220 MHz to keep ≥10% headroom, which is *fine* (a closed design at an honest frequency beats an OOC fantasy).

### XIV.5 Out-of-context (OOC) — what it gives and what it hides

**Plain version.** ArchBetter's current builds run **out-of-context (OOC)** — a mode where the tool implements your block *without* connecting it to real chip pins or a real clock source. Why? Because `archbetter_core` exposes ~6564 internal signals as ports (for the testbench to drive), and a chip only has 386 pins — they don't fit. OOC lets you get fabric-level area and timing numbers without solving the pin problem. But OOC *hides* real things: no I/O power, no clock-tree power, partial design-rule checks, and an idealized clock. So OOC numbers are a useful *lower bound on the fabric* but are **not** a publishable whole-chip result. Getting out of OOC (Part XVI) is the current top priority.

**Technical version.** OOC (`synth_design -mode out_of_context`) treats top ports as virtual nets — no IBUF/OBUF insertion, no pin placement. Consequences in your reports: `0 Bonded IOB`, `0 MMCM`, the `RTSTAT-10` "no routable loads" on boundary nets, the false `[Timing 38-242] HD.CLK_SRC not set`, the phantom CDC "critical," and an incomplete `report_drc`. Power under OOC is doubly unreliable (no I/O/clock-tree contributions + idealized activity). **Bankable from OOC**: utilization (real fabric primitives), intra-clock timing slack (idealized), DSP/URAM/BRAM counts, methodology cleanliness. **Not bankable**: power, full DRC sign-off, true clocked timing. The whole closure plan exists to replace OOC with a pinned, clocked, non-OOC build.

### XIV.6 Resource inference and the methodology warnings you saw

**Technical version.** Synthesis *infers* primitives from RTL patterns; attributes steer it. Examples grounded in your build: the 256-entry descriptor table is forced to a flop register file (`ram_style="registers"`) because its read is *asynchronous* (a BRAM can't serve a zero-latency combinational read) — `[Synth 8-4767]` is informational, the choice is correct (~16K of the 65.6K FFs). The KV BRAMs trip `SYNTH-6` ("no output register merged") — a *timing* hint (the optional BRAM output register would improve `f_max`), waived because the access pattern needs the un-registered read. `noise_rd_in` ports show `[Synth 8-7129]` "unconnected" because `ENABLE_NOISE_HOOKS=0` prunes them — expected. The discipline (CLAUDE.md §5): every advisory is *triaged* and either fixed or **waived with written justification** in `waivers.tcl` — never silenced blindly.

---

## Part XV — Verification: making sure it's actually correct

### XV.1 Why verification is most of the work

**Plain version.** In hardware, a bug found after fabrication can cost millions and months — you can't patch silicon. So you prove correctness *before* building, in simulation, exhaustively. The rule of thumb: verification is 60-70% of a chip project's effort. ArchBetter's rule is blunt — "a module without a testbench does not exist." Every block ships with a **testbench**: a simulation harness that feeds it inputs and checks its outputs against a known-correct **golden reference**.

**Technical version.** Each RTL module has a peer `tb_<dut>` in `src/tb/` mirroring its `src/rtl/` location. The methodology (CLAUDE.md §3): **bottom-up** — `cim_cell → pe → group → sparse tile → noc_router → dispatcher → memory_manager → top` — each green before the next, then a top-level integration TB, all passing before *any* synthesis. This catches bugs at the smallest scope where they're cheapest to localize.

### XV.2 Golden models, scoreboards, and the bug we already fixed

**Plain version.** To check hardware, you need something to check it *against*: a **golden model** — an independent, simple, obviously-correct implementation of the same math (often in plain SystemVerilog or Python). The testbench runs both the hardware design and the golden model on the same inputs and compares every output (a **scoreboard**). If they ever disagree, you have a bug — in one or the other. Earlier in this project, exactly this caught a problem: the `cim_cell` golden model was written for a 3-stage pipeline, but the hardware had been upgraded to 4 stages, so the golden's accumulator ran one cycle ahead — thousands of "mismatches" that were actually the *test* being stale, not the hardware. Fixing the golden to mirror the 4-stage pipeline made it pass. **Lesson: when the design's timing contract changes, its golden must change in lockstep.**

**Technical version.** A **self-checking testbench** drives directed corner cases (zero, ±1, sign extremes, max-magnitude) *and* randomized stimulus wrapping a golden reference, comparing cycle-by-cycle. The `cim_cell` golden mirrors the exact `A1→A2→M→P` pipeline so `acc_out`/`acc_valid` match bit-exactly every cycle. **Coverage** (functional + code) measures how much of the state space the tests exercised — high coverage is the evidence that "passes" means "correct," not "untested." The closed-loop `tb_archbetter_core` proves a full dispatcher-orchestrated layer end-to-end (133 checks, 0 errors) — and now also carries the STAGE-5 throughput instrumentation.

### XV.3 Assertions — contracts that check themselves

**Plain version.** An **assertion** is a statement of something that must *always* be true ("a FIFO never overflows," "these two control signals never fire together"), written into the design itself so the simulator screams the instant it's violated — pinpointing the exact cycle and cause. They turn silent, subtle bugs into loud, located ones.

**Technical version.** SystemVerilog Assertions (**SVA**): immediate (`assert(cond)`) and concurrent (`assert property (@(posedge clk) ...)`). ArchBetter's interfaces carry handshake assertions (valid-stable-under-backpressure, no-transfer-without-ready); FIFOs assert fill/overflow/underflow; the `cim_cell` asserts its 4-cycle latency and the `w_we`/`a_valid` non-concurrency contract. All guarded by `` `ifndef SYNTHESIS `` so they cost nothing in the real chip. Assertions are *executable specification* — they encode the contract Part IX's latency-insensitive design depends on.

### XV.4 The simulation toolchain in this project

**Technical version.** Vivado **XSim**, `xil_defaultlib`, per-testbench `run_tb_*.tcl` scripts. Operational gotchas captured during this project: editing `types_pkg`/`interfaces.sv` requires deleting `project_1.sim` (stale `.sdb` → VRFC 10-3006/10-3032 false errors); `[Common 17-180] Spawn failed` is a transient Windows process flake (re-run, don't edit); SAIF capture is via `xsim.simulate.saif_scope=dut`. The user runs sims manually; I edit RTL + the run scripts.

---

## Part XVI — SoC integration and closure: getting to a real chip

### XVI.1 What "closure" means and why OOC isn't it

**Plain version.** **Closure** = a fully implemented design that meets timing, fits real pins, has a real clock, passes all checks, and produces a loadable bitstream — a result you can defend and (eventually) run on hardware. ArchBetter is *not* closed yet because it's stuck in OOC (the 6564-port problem). The plan to close it is a thin **wrapper** that bundles those thousands of internal signals behind a small number of real interfaces, so the design fits on pins and can be built non-OOC.

**Technical version.** The journal artifact requires a **non-OOC, fully-pinned, clocked** implementation with vectored power. The blocker is the wide port surface; the fix is `archbetter_soc_top`, a wrapper that: (1) bundles host ports behind a **narrow control/loader interface** (imem, CSD descriptors, layer base addrs, start/done) so the design fits 386 pins; (2) adapts the native `csd_dram_if`/`csd_dram_wr_if` to an **AXI4 master** seam with the **DDR4 MIG as a swappable block**; (3) generates the compute clock via an **MMCM** with a synchronized reset. `archbetter_soc_top` is the *only* board-specific file — everything at `archbetter_core` and below is untouched across KU5P↔VU9P.

### XVI.2 The memory controller (MIG) and the AXI seam

**Plain version.** Off-chip DRAM (DDR4) is its own complex protocol — refresh, banks, timing, calibration. You don't hand-build that; you use a vendor-generated **Memory Interface Generator (MIG)** that presents a clean, simple interface (AXI) on the inside and drives the DDR4 pins on the outside. ArchBetter's compute core talks to a simple AXI "memory port"; the MIG sits behind it as a swappable block. This is the key to portability: moving from one board to another (KU5P → VU9P) means regenerating the MIG and swapping pins — the accelerator itself doesn't change.

**Technical version.** The DDR4 MIG presents an **AXI4 slave** to the accelerator's AXI4 master; it owns DDR4 PHY calibration, refresh, and bank management. By making the accelerator memory-controller-agnostic at the AXI boundary, the MIG becomes the *single* device/board-specific block. **Power-boundary discipline**: `report_power` is hierarchy-scoped to the accelerator; DRAM/MIG declared external (accelerator-core power). This matches the "accelerator-core power" reporting common in the cohort and keeps the comparison honest.

### XVI.3 Clocking, reset, and CDC for real

**Plain version.** A real chip gets its clock from a crystal oscillator on the board, but accelerators need specific (often higher) frequencies — so an on-chip **clock manager (MMCM/PLL)** multiplies the board clock up to the compute frequency. Reset must be released *synchronously* with the clock to avoid glitches. And anywhere two different clocks meet, you need safe crossing logic (Part VIII.3). In OOC none of this is real, which is why the OOC clock is "idealized"; closure makes it real, which is when the true timing margin shows.

**Technical version.** An **MMCM** generates `clk_compute` from the board oscillator; a reset synchronizer releases `rst_n` cleanly in-domain. A separate memory clock (DRAM domain) crosses to compute via XPM CDC macros. The non-OOC build then models the **real clock tree** (BUFG insertion delay, skew), giving the true WNS — the number that replaces the optimistic OOC +0.057 ns. Single-SLR floorplanning (`pblock`) on VU9P avoids SLR-crossing penalties (the design is ~3-4% of VU9P).

### XVI.4 The closure roadmap (C1–C6)

**Technical version.** **C1** — representative prefill+decode workload + throughput instrumentation (in progress; STAGE-5 perf done, workload realism next). **C2** — AXI4 memory seam + behavioral DDR responder for sim. **C3** — `archbetter_soc_top` (MMCM + control loader + AXI memory). **C4** — device-split XDC (portable timing + board physical + single-SLR pblock). **C5** — non-OOC synth→impl→bitstream, zero warnings, real clock-tree closure. **C6** — vectored SAIF power (representative workload, accelerator-scoped) → tokens/s, GOPS, energy/token. Each phase ends sim-clean + zero-warning per the §3 discipline.

---

## Part XVII — The SOTA landscape and honest comparison

### XVII.1 The cohort and the axes

**Plain version.** ArchBetter is judged against the best published edge-LLM FPGA accelerators: **FlightLLM**, **TeLLMe**, **EdgeLLM**. The claim is *not* "we beat them on one number" — it's "we beat them on the *combined frontier* of time-to-first-token × throughput × energy-efficiency × latency × compute-density." Cherry-picking one axis is what weak papers do; reviewers respect a design that's better *overall* at the same job. Separately, ArchBetter calibrates against an **analog 4T2R ReRAM CIM macro** (59-95.3 TOPS/W) — but that's a *ceiling reference*, not an apples-to-apples rival (it's an analog tile with no system overhead), and claiming TOPS/W parity with it on an FPGA would be caught instantly.

**Technical version.** Comparison axes: **TTFT** (prefill latency), **throughput** (prefill + decode tok/s), **energy efficiency** (TOPS/W, tokens/J), **latency** (dispatch→first token), **compute density** (GOPS/mm² or GOPS/LUT/DSP). Method discipline: compare *same workload* (model, sequence length, batch), *same measurement methodology* (post-route vectored power, stated I/O boundary), *same device class* (edge — hence KU5P headline, never VU9P). **FlightLLM** (FPGA'24, U280/VHK158): sparse + mixed-precision, configurable-sparse DSP chains, instruction-level abstraction — ArchBetter's macro-ISA + dispatcher lineage. **EdgeLLM / TeLLMe**: edge-FPGA, ternary/low-bit FFN — ArchBetter's sparse-core lineage. The honest framing: ArchBetter's contribution is the **system** (the three novelties + the SoC a CIM macro lacks), demonstrated on a credible edge part with defensible (vectored, non-OOC) numbers.

### XVII.2 Why comparisons go wrong (and how to not get caught)

**Technical version.** The classic dishonest moves, all of which a TVLSI reviewer hunts for: (1) **peak instead of achieved** GOPS (hide utilization); (2) **vectorless power** dressed as measured; (3) **OOC numbers** without I/O/clock; (4) **different workload** than the baseline (shorter sequence, smaller model, higher batch); (5) **excluding** DRAM/IO power without saying so; (6) **TOPS/W parity** claims against analog CIM. ArchBetter's entire measurement discipline (representative SAIF, non-OOC closure, stated boundary, both prefill+decode, KU5P-only headline) is structured to be immune to each. *Knowing these traps is what separates a designer from a marketer.*

---

## Part XVIII — Glossary (every term, one place)

**Accelerator** — hardware specialized to run a workload (here, LLM inference) faster/cheaper than a CPU/GPU. **ADC** — analog-to-digital converter; digitizes analog CIM column currents. **Activity factor (α)** — average switching probability per node; the workload-dependent term in dynamic power. **Amdahl's Law** — speedup capped by the serial fraction. **Arithmetic intensity (I)** — FLOPs per byte moved; locates a workload on the roofline. **ASIC** — application-specific IC; custom silicon (vs FPGA). **Autoregressive** — generating one token at a time, each conditioned on the prior. **AXI** — ARM's heavyweight on-chip bus protocol; used at the DRAM/SoC seam, *not* inside the fabric. **Backpressure** — receiver stalling a sender via `ready`. **BFP (Block Floating Point)** — a block of mantissas sharing one exponent. **BFP12** — ArchBetter's 12-bit mantissa / 8-bit shared-exp(per 16) format. **Bitstream** — the file that configures an FPGA. **BRAM** — Block RAM (36 kbit on-chip blocks); holds the KV cache here. **BPE/SentencePiece** — sub-word tokenizers. **CDC** — clock-domain crossing; needs synchronizers to avoid metastability. **CIM** — compute-in-memory; doing MACs inside memory via physics. **CLB** — configurable logic block (LUTs+FFs). **CMRR** — common-mode rejection ratio; how well a differential amp ignores common-mode signals (key to AC refresh). **Critical path** — longest logic delay between flops; sets `f_max`. **CSD engine** — decompress/dequant-on-the-fly DRAM→URAM fill. **Dataflow** — which operand stays stationary (WS/OS/IS/RS/NLR). **Decode** — autoregressive per-token generation; memory-bound. **Dequantization** — converting a quantized format back toward full precision (here qN→BFP12). **Dispatcher** — decodes the macro-ISA and fans out sub-ops. **Double buffering / ping-pong** — two buffers to hide fill latency. **DRAM** — off-chip bulk memory (DDR4 here). **DSP48E2** — UltraScale+ hardened multiply-accumulate slice. **Dynamic power** — `αCV²f`, the switching cost. **Embedding** — token-id → vector lookup. **EWMA** — exponentially-weighted moving average (the shred counter). **FFN** — feed-forward network; the per-token MLP in a Transformer block. **FIFO** — first-in-first-out queue decoupling producer/consumer. **FLOP** — floating-point operation; a MAC = 2 FLOPs. **f_max** — maximum clock frequency a design closes at. **FPGA** — field-programmable gate array. **Fused MACC** — multiply+accumulate in one pipelined DSP. **GEMM/GEMV** — general matrix-matrix / matrix-vector multiply. **Golden model** — independent correct reference for checking RTL. **GOPS/TOPS** — giga/tera operations per second. **GQA** — grouped-query attention; shrinks the KV cache. **Hold time** — min-delay constraint (data not too early). **IMEM** — on-chip instruction memory for the macro-ISA. **Inference** — running a trained model (vs training). **Initiation Interval (II)** — cycles between new pipeline inputs. **KV cache** — stored Keys/Values of past tokens; the core decode data structure. **Latency-insensitive** — design correct regardless of sub-block delays, via handshakes. **Leakage / static power** — power burned just being on. **Little's Law** — `L=λW`, occupancy=rate×latency. **LUT** — lookup table; the FPGA's basic logic element. **LUTRAM** — small distributed RAM built from LUTs (TLMM tables). **MAC** — multiply-accumulate. **Macro-ISA** — coarse-grained accelerator instruction set. **Mantissa** — the significant digits of a number (vs exponent). **Memristor** — programmable-resistance memory device (ReRAM). **Metastability** — undefined flip-flop state from sampling a changing async signal. **Methodology check** — Vivado's lint for timing/CDC/coding hazards. **MIG** — memory interface generator (DDR4 controller). **MMCM** — mixed-mode clock manager; generates/divides clocks. **NoC** — network-on-chip. **Non-idealities** — analog imperfections (noise, drift, variation) the twin models. **OOC** — out-of-context build (no pins/clock); fabric-only numbers. **Operator fusion** — keeping intermediate results on-chip across ops. **Output-stationary** — accumulators pinned; both operands stream. **Perplexity** — model-quality metric (lower=better); what quantization risks raising. **PE** — processing element; one MAC lane. **Pipelining** — staged execution for higher clock/throughput at latency cost. **Prefill** — processing the whole prompt at once; compute-bound. **Quantization** — representing weights/activations in fewer bits. **ReRAM** — resistive RAM (memristor). **Residual connection** — add-the-input-back skip path. **RMSNorm** — Llama's normalization. **RoPE** — rotary positional embedding. **Roofline** — performance = min(compute peak, intensity×bandwidth). **RTL** — register-transfer level. **SAIF** — switching-activity file for vectored power. **Saturation** — clamp-on-overflow (vs wrap). **Setup time** — max-delay constraint. **Skid buffer** — depth-1/2 FIFO to break a `ready` path. **Slack** — deadline minus arrival; negative = violation. **SmoothQuant** — migrating activation outliers into weights. **Softmax** — normalize scores to a probability distribution. **SoC** — system-on-chip. **SRL** — shift-register LUT primitive. **SSI/SLR** — stacked-silicon (multi-die) FPGA / super-logic-region. **STA** — static timing analysis. **Static probability** — fraction of time a net is high (in SAIF). **Streaming protocol** — lean `data/valid/ready/last` handshake. **SVA** — SystemVerilog assertions. **Systolic array** — rhythmic neighbor-connected PE grid. **Temporal vs spatial reduction** — summing over time (one adder) vs over space (adder tree). **Ternary** — `{−1,0,+1}` weights; multiplier-free. **Tile/tiling** — chopping a matrix into on-chip-sized blocks. **TLMM** — table-lookup matrix multiplication (sparse core). **Token** — a text unit the model processes. **TOPS/W** — energy efficiency (ops per joule). **Transformer** — the attention+FFN block architecture. **TTFT** — time to first token. **Tokenizer** — text→tokens. **URAM** — UltraRAM (288 kbit on-chip blocks); holds weights/activations. **Utilization** — achieved ÷ peak compute. **Vectorless power** — guessed activity (not measurement). **von Neumann bottleneck** — the compute↔memory data-movement cost. **WNS/TNS/WHS/THS** — worst/total negative slack (setup/hold). **Weight-stationary** — weights pinned; activations stream. **XPM** — Xilinx parameterized macros (CDC/FIFO/memory primitives). **Ping-pong** — see double buffering.

---

## Part XIX — Flaws, risks, and open problems (read before believing any claim)

**Plain version.** An elite designer is defined by knowing where their design is *weak*, not by pretending it's perfect. Here is ArchBetter's honest weakness list — these are the things a reviewer will attack and the things to fix.

**Technical version — the live risk register:**

1. **No real throughput/efficiency numbers yet.** Everything compute-side has been OOC + toy-workload. The 0.11% decode utilization is a *workload* artifact, not the fabric's ceiling — but until a representative prefill (DSP-saturating) + decode (resident-weight) benchmark runs, "world-class" is unproven. **This is the #1 open item.**
2. **Power is not yet real.** Vectorless + OOC + (when SAIF was added) a 5% net-match bug. Needs: `read_saif -strip_path` fix (done), representative workload, non-OOC closure, ideally post-route timing-sim SAIF. Until then, no watt enters the paper.
3. **Timing headroom is thin and optimistic.** WNS +0.057 ns @ 250 MHz is 1.4% (target ≥10%), on an *idealized* OOC clock. The critical path (NoC router → dense DSP) needs pipelining, and the real clock tree may force a lower frequency. Likely the most publication-threatening number.
4. **Decode dataflow reloads weights per tile.** The output-stationary, weight-streaming mapping is great for prefill but pathological for decode (each tile pays a full weight scan for one beat). Needs a **resident-weight decode mode** in the tile-walker. This is an architectural gap, not just a benchmark choice.
5. **The analog novelties are unsimulated.** The AC-drift-refresh µW/frequency/amplitude numbers are **TBD-pending-SPICE**; the digital twin's noise hooks are placeholders. The device-physics claim must land in a separate letter with real simulation before it's cited. Over-claiming here is the fastest way to lose credibility.
6. **Shred oracle perplexity safety is asserted, not yet measured.** The promote-on-error path is designed; its actual perplexity protection needs a model-level evaluation (golden PPL sweep) to prove the "insurance" works.
7. **dense→sparse forwarding is a boundary tap, not on-chip.** In `archbetter_core` the d2s FIFO reaches output pins, not an internal sparse-core consumer; if the dataflow narrative implies on-chip FFN forwarding, that loop isn't closed yet.
8. **Descriptor table over-provisioned.** 256 deep × 62 bit register file = ~16K FFs (24% of all flops) for what may be a handful of live descriptors — cheap to right-size if FFs ever tighten.
9. **Single-clock so far.** A real system likely needs a separate memory clock; the CDC discipline (XPM only) is specified but the multi-clock closure isn't built.
10. **VU9P temptation.** It's bigger and easier to close on, but it's *datacenter-class* — using its numbers as the headline collapses the "edge" framing. Discipline: KU5P headline, VU9P validation only.

**The meta-lesson.** Every item above is a known, named, bounded risk with a concrete next step — that is what "engineering" means versus "hoping." The architecture's *ideas* are strong and its *correctness* is proven; its *measured competitiveness* is still ahead of us, and the path to it (the C1-C6 closure) is the work that turns a promising design into a defensible paper.

---

*End of the masterclass. This document is living — update it as the architecture evolves, exactly as CLAUDE.md is the source of truth for contracts and this is the source of understanding for the people who build against them.*
