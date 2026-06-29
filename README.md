# 4T2R-SENSITIVE-Accelerator

A research-oriented accelerator for edge LLM inference built around a digital twin of a 4T2R ReRAM-based CIM fabric. This repository captures the RTL, verification flow, analytical model, and the experimental story behind the design.

## Why this project exists

ArchBetter is a hardware-software research prototype aimed at pushing edge LLM serving forward by combining:

- a dense compute core for BFP12-style matrix work,
- a sparse/ternary execution path for efficiency-minded FFN traffic,
- a staged memory hierarchy with URAM ping-pong support and KV-cache handling,
- and a dispatcher-driven control plane for coordinated execution.

The goal is not just to build hardware, but to build a credible research artifact that can be explained, compared, and defended.

## What the project shows

This work is organized around three main ideas:

1. Dense compute with a 4T2R-inspired digital twin
2. Sparse acceleration for ternary-weight workloads
3. A full-stack memory and control strategy that makes the system practical

The design is meant to be read as a full architecture story, not just a collection of RTL files.

## Key results

The project targets the edge-LLM frontier with a focus on throughput, latency, energy, and the ability to serve real model workloads.

- Peak dense-core throughput model: about 230 GOPS at the stated operating point
- Measured reload-bound corner: roughly 8.69 GOPS at the small-K reference point
- Power model: about 1.5 W for the accelerator core at the reported operating point
- Decode-oriented operating band: competitive token throughput with the shred-based compression strategy
- Research framing: the design is positioned as a full SoC-level contribution, not a raw analog macro comparison

## Architecture at a glance

The project is organized around a hybrid pipeline:

- Dense core for the main GEMM-style compute path
- Sparse core for ternary-friendly operations
- Memory manager for URAM staging, CSD fill logic, and KV-cache flow
- NoC and dispatcher to route data and schedule execution

## Visual overview

### System view

![System overview](topView.png)

### Circuit and cell view

![Circuit and cell view](CircuitView.png)

### Utilization view

![Utilization view](UTilization.png)

### Timing view

![Timing view](timing.png)

### Power view

![Power metrics](powerMetrics.png)

### Speed and throughput view

![Speed and throughput view](speed.png)

### Digital-twin and perplexity view

![Digital-twin and perplexity view](digitalTwinPerplexity.png)

## Repository structure

```text
src/          # RTL, testbenches, constraints, scripts
 docs/        # research notes and design documents
 tools/       # analytics and modeling utilities
```

## Research documents

The repository includes the following supporting documents:

- [docs/ARCHBETTER_MASTERCLASS.md](docs/ARCHBETTER_MASTERCLASS.md)
- [docs/ANALYTICS_MODEL.md](docs/ANALYTICS_MODEL.md)
- [docs/LITERATURE_SURVEY_2026.md](docs/LITERATURE_SURVEY_2026.md)
- [docs/WEIGHT_RESIDENCY_DESIGN.md](docs/WEIGHT_RESIDENCY_DESIGN.md)

These documents explain the architectural reasoning, the analytical model, and the research positioning.

## Getting started

### Prerequisites

- Vivado 2025.2
- Xilinx UltraScale+ targeting flow
- Git

### Open the project

```bash
vivado project_1.xpr
```

### Explore the design

The RTL and verification flow live under the src tree. The supporting research and modeling material lives under docs and tools.

## Note on source visibility

Because this project is intended for research publication, the source tree can be kept private or moved to a restricted-access repository if you want a stricter boundary between public-facing material and the full implementation. GitHub does not support making only one subfolder private inside a public repository, so the closest options are either:

- keep the repository private and publish a public landing page separately, or
- keep the public-facing material here and host the complete RTL in a private repository

If you want, I can help set up that private/public split next.

## License

This repository is provided as a research and prototyping codebase. Please review the licensing terms before using it in publications or broader distribution workflows.
