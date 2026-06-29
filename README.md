# 4T2R-SENSITIVE-Accelerator

A research-oriented hardware accelerator prototype for edge-LLM inference, centered on a digital twin of a 4T2R ReRAM-based CIM fabric. This repository captures the RTL, testbenches, scripts, and supporting analysis workflow for an accelerator architecture designed around dense computation, sparse acceleration, memory staging, and a circuit-switched interconnect.

## Overview

This project implements a hybrid accelerator architecture that combines:

- A dense compute core based on a BFP12-style grouped vector systolic fabric.
- A sparse execution path for ternary-weight operations using TLMM-style lookup tables.
- A staged memory subsystem based on URAM ping-pong banks, CSD-style fill logic, and KV-cache support.
- A macro-instruction dispatcher and NoC fabric to orchestrate data movement and compute.

The design is intentionally structured as a simulation-first, methodology-clean RTL repository for research and FPGA/Vivado-based prototyping.

## Goals

The repository is organized around the following goals:

1. Provide a clean, modular RTL implementation of a dense/sparse edge-LLM accelerator.
2. Preserve a strong separation between compute, memory, and interconnect subsystems.
3. Support testbench-driven verification and golden-reference style validation.
4. Keep the implementation compatible with a Vivado 2025.2 style workflow on Xilinx UltraScale+ targets.
5. Provide a research artifact that can be used for architecture exploration, paper drafting, and further hardware development.

## Architecture Summary

### Dense Core

The dense core models a logically large matrix-vector compute fabric using a physically smaller time-multiplexed kernel. The system uses:

- Dense PE logic with a 4T2R digital twin abstraction.
- Group-level accumulation and array-level accumulation structures.
- A weight-streaming and activation-distribution pipeline.

### Sparse Core

The sparse path targets ternary weights and uses table-based compute rather than DSP-heavy multiply logic. This keeps the sparse core lightweight while supporting efficient sparse activation patterns.

### Memory Subsystem

The memory subsystem includes:

- URAM-based ping-pong staging for dense and sparse workloads.
- CSD-style fill and drain logic.
- BRAM-backed KV-cache support.
- Shred/precision management hooks for memory reclamation and reuse strategies.

### Interconnect

The architecture uses a circuit-switched NoC and dispatcher-based control plane to configure and schedule data movement before execution. This makes the design suitable for a research-style accelerator substrate rather than a generic AXI-centric fabric.

## Repository Structure

```text
src/
  rtl/
    common/
    dense_core/
    sparse_core/
    memory/
    noc/
    dispatcher/
    top/
  tb/
  constraints/
  params/
  scripts/
```

## Toolchain and Flow

This repository is designed around:

- Vivado 2025.2
- XSim simulation
- SystemVerilog RTL
- TCL-based build and simulation scripts

Typical flow:

1. Add sources using the provided TCL scripts.
2. Run the relevant testbench from the simulation flow.
3. Synthesize and implement after the simulation checks are clean.
4. Use the provided reports and scripts for timing, utilization, CDC, and power analysis.

## Verification Strategy

The codebase is organized to support:

- Unit-level RTL testbenches for each subsystem.
- Integration testbenches for the broader top-level architecture.
- Gold-reference style checks for compute logic.
- Simulation-driven validation before synthesis.

## Notes

This repository is intended as a research hardware prototype rather than a finished production-ready product. The RTL and surrounding scripts are structured to support rapid exploration of accelerator organization, dataflow choices, and system-level tradeoffs.

## Getting Started

### Prerequisites

- Vivado 2025.2 or compatible installation
- A supported Xilinx UltraScale+ target board or part
- Git and a GitHub account

### Clone

```bash
git clone https://github.com/<your-user>/4T2R-SENSITIVE-Accelerator.git
cd 4T2R-SENSITIVE-Accelerator
```

### Run the project

Open the project file in Vivado:

```bash
vivado project_1.xpr
```

Or use the provided build scripts from the repository root.

## License

This repository is provided as a research and prototyping codebase. Please review and confirm the licensing terms before using it in a publication, commercial product, or broader distribution workflow.
