# ArchBetter — End-to-End Analytical Model (KU5P prototype)

> **Purpose.** A first-principles, *traceable* derivation of every performance, power,
> energy, efficiency and area metric for the ArchBetter SoC on `xcku5p-ffvd900-3-e`,
> at the BATCH_T=64 / 225 MHz closed implementation. This is the methodology/scaffold
> the digital twin populates with validated data. Companion to `CLAUDE.md` (§ source of
> truth), `docs/ARCHBETTER_MASTERCLASS.md` (Part XII/XIII model vocabulary), and
> `docs/LITERATURE_SURVEY_2026.md` (cohort). Numbers reproduced by
> `tools/analytics/archbetter_analytics.py`.

## 0. Evidence tiers (every number below carries one)

| Tier | Meaning | Trust |
|---|---|---|
| **[M]** Measured | cycle-exact from RTL simulation / exact from impl reports | data — goes in the paper as-is |
| **[A]** Architectural | exact from resource count × clock | exact |
| **[P]** Projected | model + *stated* assumptions (§4 list) | estimate, sensitivity disclosed; the **twin** converts these to data |

**A note on algebraic vs differential models.** The headline metrics (throughput,
utilization, GOPS/W, GOPS/mm², energy/token) are **algebraic closed forms** — ratios and
products of rates and counts. They are *not* differential equations, and modeling them as
such would be incorrect. Dynamical (difference/differential) equations are the correct tool
in exactly three sub-systems, modeled in §7–§9: the **shred EWMA** (§9, a novelty), the
**thermal transient** (§8.4), and **conductance drift** (device-physics letter, out of scope
here). We use ODEs only where the state genuinely evolves in time.

## 1. Symbols and constants [A] (exact, `reports/util.rpt`, `timing.rpt`)

| Symbol | Value | Meaning |
|---|---|---|
| $N_{PE}$ | 512 | physical MAC PEs (2 × dense_group, 16×16, 1 fused DSP48E2/PE) |
| $f$ | $225\times10^{6}$ Hz | compute clock (MMCM clkout0); WNS = +0.152 ns (met) |
| $\varphi$ | 2 | ops per MAC (1 mul + 1 add) |
| $N_{DSP}$ | 512 | DSP48E2 used (of 1824 → 28.1 %) |
| $N_{LUT}$ | 31 659 | CLB LUTs (14.6 %) |
| $N_{FF}$ | 63 357 | flip-flops (14.6 %) |
| $N_{BRAM}$ | 91.5 | RAMB36-equiv (19.1 %) |
| $N_{URAM}$ | 11 | URAM288 (17.2 %) |
| $V$ | 0.90 V | $V_{ccint}$ |
| $\theta_{JA}$ | 1.4 °C/W | junction-to-ambient (medium heatsink, 250 LFM) |
| $w$ | 128 bit | AXI memory-seam width (DRAM/MIG external, §11) |

Derived device constants:

$$M_{peak}=N_{PE}\,f = 512\cdot 225\!\times\!10^{6}=1.152\times10^{11}\ \text{MAC/s}=115.2\ \text{GMAC/s}$$
$$\Theta_{peak}=\varphi\,M_{peak}=230.4\ \text{GOPS}$$
$$\beta_{AXI}=\frac{w f}{8}=\frac{128\cdot 225\!\times\!10^{6}}{8}=3.6\ \text{GB/s}\quad(\text{closure seam; the decode roofline slope, §7.2})$$

## 2. Throughput [A]/[M]

**Achieved throughput** for a workload of $W$ MACs taking $N_{cyc}$ cycles:

$$\Theta_{ach}=\frac{\varphi\,W}{t},\qquad t=\frac{N_{cyc}}{f}.$$

**Utilization** (the number reviewers check first):

$$\eta=\frac{\Theta_{ach}}{\Theta_{peak}}=\frac{W/N_{cyc}}{N_{PE}}=\frac{\text{MAC per cycle}}{N_{PE}}.$$

**[M] Measured micro-benchmark** (`tb_archbetter_soc_top_sustained`, 8×2 layer, $K{=}1$, $T{=}64$):
$W = C\cdot R\cdot T = 64\cdot128\cdot64 = 524\,288$ MAC; $N_{cyc}=27\,165$; $t=120.7\ \mu s$.

$$\Theta_{ach}=\frac{2\cdot524288}{120.7\!\times\!10^{-6}}=8.69\ \text{GOPS},\qquad
\eta=\frac{19.3}{512}=\boxed{3.77\%}.$$

This is the **reload-bound $K{=}1$ corner** — the honest *floor*, not a headline (§3 explains).

## 3. The amortization law — why $\eta$ rises with reduction depth (Amdahl form) [A]+[P]

Decompose the layer cycle budget into a depth-independent overhead and compute:

$$N_{cyc}=N_{ovh}+N_{comp},\qquad N_{comp}=\frac{W}{N_{PE}\,\eta_{pipe}}.$$

At the measured point $N_{comp}^{ideal}=W/N_{PE}=1024$ cyc, so $N_{ovh}=27\,165-1024=26\,141$ cyc
(CSD fill + 16 weight reloads + per-token drain/snap/rearm + ST_OUT + FFN + barriers — roughly
fixed per weight residency). Utilization as a function of work:

$$\boxed{\;\eta(W)=\frac{N_{comp}}{N_{comp}+N_{ovh}}=\frac{1}{1+\dfrac{N_{ovh}\,N_{PE}}{W}}\;}$$

This is **Amdahl's law** for the accelerator: as the reduction depth $K$ grows (a real LLM layer
has $K=d_{model}=2048$, not 1), $W\propto K$ grows while $N_{ovh}$ is ~fixed, so $\eta\to1$. It is
**algebraic**, not differential. The $K{=}1$ micro-benchmark sits at the worst end ($W$ tiny →
$\eta=3.77\%$); a real layer amortizes the fixed cost. **[P]** Conservative deep-$K$ band
$\eta_{prefill}\in[0.75,0.90]$ (used in §7.1); the twin measures the true value.

## 4. Projection assumptions (the only knobs §7+ depend on) [P]

| # | Assumption | Value (band) | Resolved by |
|---|---|---|---|
| A1 | deep-$K$ prefill util $\eta_{prefill}$ | 0.85 (0.75–0.90) | cycle twin |
| A2 | external DRAM bandwidth $\beta$ | board-dependent: 3.6 / 14.4 / 25.6 / 51.2 GB/s | board + seam width |
| A3 | BFP12 bytes/param $b_{12}$ | $(12+8/16)/8 = 1.5625$ B | exact (format) |
| A4 | ternary bytes/param $b_{t}$ | $1.58/8 = 0.1975$ B | exact (format) |
| A5 | shred avg compression $\sigma$ | 1.8× (1.4–2.0) | **perplexity twin** |
| A6 | ternary-FFN fraction usable at target PPL | 0 → 0.79 | **perplexity twin** |

A5/A6 are *gated by perplexity*: they set how aggressively weights compress, which sets decode
bandwidth (§7.2). This is why the twin is the pivotal experiment — it converts A1, A5, A6 from
assumptions to measured values.

## 5. Throughput / area [A]

FPGA "area" is reported resource-normalized (lit survey §3.6); absolute $\text{GOPS/mm}^2$ needs the
XCKU5P die area, which is **not publicly exact** — so we do **not** fabricate it. Exact proxies:

$$\frac{\Theta}{N_{DSP}}\Big|_{peak}=\frac{230.4}{512}=0.450\ \tfrac{\text{GOPS}}{\text{DSP}},\qquad
\frac{\Theta}{N_{LUT}/10^3}\Big|_{peak}=\frac{230.4}{31.659}=7.28\ \tfrac{\text{GOPS}}{\text{kLUT}}.$$

At projected prefill ($\eta_{prefill}{=}0.85$): $0.382$ GOPS/DSP, $6.19$ GOPS/kLUT.
**Headroom matters here:** we use 28 % of DSPs; the device dense ceiling is
$1824\cdot225\!\times\!10^6\cdot2 = \mathbf{0.82\ TOPS}$ (the Phase-9 4-group scale-up), *plus* the
LUT-based TLMM sparse core, whose effective throughput on ternary FFN is **not DSP-bounded** and is
additive. The 230 GOPS figure is the dense core at one conservative operating point, not the ceiling.
For an ASIC area number, project the netlist resource mix onto a 16 nm standard-cell area model (future
work — flagged, not estimated here).

## 6. Power model [M]/[A]

Dynamic power is the standard switching model, summed over resources:

$$P_{dyn}=\sum_{r}\alpha_r\,C_r\,V^{2}f .$$

We do not have per-net $C_r$; `report_power` evaluates this sum and reports the per-resource result
(post-route, behavioral-SAIF annotated — overall confidence Low at 6 % net match, but **each row is
anchored by exact resource count + High-confidence clock (`create_clock`) + matched-register activity**;
the dominant rows are well-bounded). From `reports/power_saif.rpt`:

| $r$ | $P_r$ (W) | % dyn | activity-dependence |
|---|---|---|---|
| Signals | 0.274 | 25.3 | data (scales with util) |
| Clocks | 0.258 | 23.9 | ~fixed (toggles every cycle) |
| CLB | 0.158 | 14.6 | mixed |
| DSP | 0.130 | 12.0 | compute (scales with util) |
| BRAM | 0.099 | 9.2 | data movement |
| MMCM | 0.083 | 7.7 | fixed |
| URAM | 0.069 | 6.4 | data movement |
| I/O | 0.009 | 0.8 | fixed |
| **$P_{dyn}$** | **1.081** | 100 | |

Static (leakage), temperature-dependent: $P_{stat}=N_{dev}\,I_{leak}(V,T_j)\,V = 0.476$ W at $T_j{=}27.2$°C.

$$P_{total}=P_{dyn}+P_{stat}=1.556\ \text{W}.$$

**Accelerator-scoped power** (§11: DRAM/`u_mem` external, excluded; static apportioned by the
$u\_soc$ dynamic fraction):

$$P_{acc}=P^{u\_soc}_{dyn}+P_{stat}\frac{P^{u\_soc}_{dyn}}{P_{dyn}}
=1.053+0.476\frac{1.053}{1.081}=\boxed{1.517\ \text{W}}.$$

## 7. End-to-end on TinyLlama-1.1B [P]

Config (verifiable on HuggingFace): $L{=}22$, $d{=}2048$, $d_{ff}{=}5632$, $n_{heads}{=}32$,
$n_{kv}{=}4$ (GQA), $h{=}64$, vocab 32000, $\approx 1.1\times10^{9}$ params.

**MAC per token per layer** (attention QKVO with GQA + SwiGLU FFN):

$$w_\ell = \underbrace{2d^2}_{Q,O}+\underbrace{2d\,(n_{kv}h)}_{K,V}+\underbrace{3\,d\,d_{ff}}_{\text{gate,up,down}}
=2(2048)^2+2(2048)(256)+3(2048)(5632)=44.04\ \text{M}.$$

Per token, all layers: $W_{tok}=L\,w_\ell=968.9$ M MAC $=1.938$ GOP/token.

### 7.1 Prefill — compute-bound → TTFT

Prefill reuses each weight across all $S$ prompt tokens (high arithmetic intensity) → compute roof:

$$\text{TTFT}(S)=\frac{S\,W_{tok}}{\eta_{prefill}\,M_{peak}}\;[+\,O(S^2)\ \text{attn scores, small for short }S].$$

| $S$ | TTFT @ $\eta{=}0.85$ | band $[0.90,0.75]$ |
|---|---|---|
| 32 | 0.32 s | 0.30–0.36 s |
| 128 | 1.27 s | 1.20–1.44 s |
| 512 | 5.07 s | 4.79–5.74 s |

Prefill throughput $\approx \eta_{prefill}\Theta_{peak}=196$ GOPS (compute roof).

### 7.2 Decode — memory-bound (roofline memory roof)

Every decode token streams the whole weight set once → bandwidth-bound:

$$R_{dec}=\frac{\beta}{B_{tok}},\qquad
B_{tok}=P_{params}\big[f_{a}b_{12}/\sigma_a+f_{ffn}(\text{ternary}? b_t : b_{12}/\sigma)\big],$$

with param split $f_{ffn}=0.786$, $f_a=0.214$. Decode is **not** MAC-limited — the levers are
**quantization** (shred $\sigma$, ternary) and **bandwidth** $\beta$, exactly as the roofline predicts.

| Weight model | $B_{tok}$ (GB) | $R_{dec}$ @ 25.6 GB/s | @ 51.2 GB/s |
|---|---|---|---|
| all-BFP12, no shred | 1.72 | 14.9 | 29.8 |
| **all-BFP12 + shred** (near-lossless) | 0.95 | **27** | **54** |
| ternary-FFN + BFP12-attn | 0.54 | **47** | 95 |
| ternary-FFN + shred-attn | 0.38 | **68** | 137 |

> **Honest framing.** BFP12's fidelity costs decode *bytes*; the **shred oracle (§2.5) is the
> near-lossless lever** that brings decode to **27–54 tok/s** at standard board DRAM with *no risky
> ternary*. Ternary-FFN (47–95) is upside **iff** perplexity tolerates it (A6 — twin-gated). The
> earlier "3.9 tok/s" was the worst-case corner: the 3.6 GB/s *closure* seam × ternary-off × shred-off.

### 7.3 Energy per token

$$E_{tok}=\frac{P_{acc}}{R_{dec}}.$$

At the 30–60 tok/s operating band: $E_{tok}=25$–$51$ mJ/token (accelerator core, DRAM external).

## 8. Efficiency [P] + thermal [A]

$$\frac{\Theta}{W}\Big|_{prefill}=\frac{196}{1.517}=129\ \tfrac{\text{GOPS}}{\text{W}},\qquad
\frac{\Theta}{W}\Big|_{K=1}=\frac{8.69}{1.517}=5.7\ \tfrac{\text{GOPS}}{\text{W}}\ (\text{floor}).$$

> *Caveat:* prefill GOPS/W uses the measured (reload-bound) $P_{acc}$; at high compute util DSP/signal
> dynamic rises while fill/drain dynamic falls — net within ~±30 %. A deep-$K$ SAIF (or the twin) firms it.

**§8.4 Thermal — the one genuine ODE.** Junction temperature follows a 1st-order RC thermal network:

$$C_{th}\frac{dT_j}{dt}=P(T_j)-\frac{T_j-T_a}{\theta_{JA}}.$$

Steady state ($dT_j/dt{=}0$) is the algebraic solution $T_j=T_a+P\,\theta_{JA}$; check against the report:
$25+1.556\cdot1.4=27.18$°C ✓. With leakage feedback $P(T_j)=P_{dyn}+P_{leak,0}e^{(T_j-T_{ref})/T_0}$ the system
is nonlinear; **thermal runaway** occurs when $\theta_{JA}\,\partial P_{leak}/\partial T_j\ge1$. At 1.556 W and
$\theta_{JA}=1.4$ we are far from that bound (huge margin) — edge-deployable without active cooling.

## 9. Shred-oracle dynamics — the difference/differential equation (novelty §2.5)

The per-tile usage counter is a **leaky integrator** (Morris/approximate-counting; Flajolet 1985):

$$u[n+1]=u[n]-\big(u[n]\gg k\big)+\rho\,a[n]\;\;\Longleftrightarrow\;\;
u[n+1]-u[n]=-\frac{u[n]}{2^{k}}+\rho\,a[n],$$

with $a[n]\in\{0,1\}$ the access indicator and $\rho$ the access pulse. Its continuous-time analog is the
**1st-order linear ODE**

$$\frac{du}{dt}=-\frac{u}{\tau}+\rho\,\nu(t),\qquad \tau=2^{k}T_{epoch},$$

so for a stationary access rate $\nu$ the steady-state usage is $u^\*=\rho\,\nu\,\tau$ — i.e. **usage is a
low-pass-filtered access frequency**. Precision class follows from threshold crossings of $u^\*$
($T_{keep}>T_{dim}>T_{pen}>T_{zero}$ → BFP12/8/6/ternary/0), and the promote-on-error path adds a residual-monitored
hysteresis (the perplexity insurance). This is the *only* place in the performance model where state evolves
in time, and it is correctly a difference equation, not algebra. The averaged compression it yields is $\sigma$
(A5), validated by the perplexity twin.

## 10. Cohort comparison [P] — **annotate power scope, never compare raw**

All cohort numbers from `docs/LITERATURE_SURVEY_2026.md` (sourced). **Scope differs**: ArchBetter reports
**accelerator-core** power with DRAM external (§11); FlightLLM/EdgeLLM report **system+HBM**. This is a
*different and fairer* scope — state it, don't flatter.

| Work | Device | Class | Clock | tok/s | Power (scope) | tok/J |
|---|---|---|---|---|---|---|
| FlightLLM | U280 | datacenter | 225 MHz | 55 | 45 W (sys+HBM) | 1.22 |
| EdgeLLM | VCU128 | datacenter | — | 69.4 | 56.8 W (sys+HBM) | 1.22 |
| TeLLMe | KV260 | **edge** | 250 MHz | ~9 @1k ctx | <7 W | — |
| PD-Swap | KV260 | **edge** | — | ≤27 | KV260 (~few W) | — |
| SwiftKV | edge MHA | edge | — | 81.5 (1100 GOPS) | — | 60.12 GOPS/W |
| **ArchBetter** | **KU5P** | **edge** | **225 MHz** | **27–54 (BFP12+shred); 47–95 (ternary, PPL-gated)** | **~1.5 W (core, DRAM ext)** | **2.5–~12 (core)** |

ArchBetter's headline is the **combined edge frontier** (§0): competitive decode tok/s at **~1.5 W core**,
prefill ~196 GOPS, with three SoC novelties no cohort member carries. Raw GOPS/TOPS is *not* the edge metric
(TeLLMe is publishable at ~9 tok/s, GOPS-class) — lead with tok/s, tok/J, TTFT, and the combined frontier.

## 11. Disclosure — what is data vs what the twin must validate

- **[M]/[A] (data, paper-ready now):** peak 230.4 GOPS; measured $K{=}1$ corner 8.69 GOPS / 3.77 % util /
  120.7 µs; power 1.556 W total / 1.517 W accelerator; the per-resource breakdown; GOPS/DSP, GOPS/kLUT; the
  thermal steady-state.
- **[P] (twin converts to data):** $\eta_{prefill}$ (A1) → real prefill GOPS & TTFT; $\sigma$, ternary-FFN
  tolerance (A5/A6) → the decode tok/s row **and the perplexity claims of §2.5/§2.7**; deep-$K$ utilization.
- **The pivotal experiment** is the bit-accurate PyTorch + cycle twin: it produces **perplexity** (currently
  absent — gates every aggressive-quant decode number) and **real-shape TTFT/throughput**, turning the [P]
  rows into measured-grade results that stand beside EdgeLLM/TeLLMe.
