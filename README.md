# FreeJESD

An open-source implementation of the **JESD204B** high-speed serial interface standard, written in synthesizable RTL (SystemVerilog/Verilog).

## Overview

JESD204B is a high-speed serial interface standard defined by JEDEC, widely used to connect data converters (ADCs/DACs) to FPGAs and ASICs. FreeJESD provides a fully open, portable, and vendor-agnostic implementation of the JESD204B link layer.

## A second goal: built entirely with AI

FreeJESD has two goals running in parallel, and the second is as much the point as the first:

1. Produce a genuinely open-source, from-scratch JESD204B core — not a
   transcription of any existing repo, licensed permissively, with its own
   iverilog-runnable self-checking testbench suite (see
   [instructions/README.md](instructions/README.md) for the provenance
   policy and architectural references).
2. Do it **entirely through AI-driven development** — every line of RTL,
   every testbench, every design decision written and verified by an AI
   coding agent (Claude Code) working from a spec pack, not hand-written and
   then cleaned up afterward. The [instructions/](instructions/) folder is
   the spec the agent works from; commit history and code comments are left
   as an honest trail of what the agent got right, what it got wrong on
   first pass, and what a locally-run testbench caught and fixed — including
   real bugs, not just style nits. The point isn't to hide the seams; it's
   to see how far "spec pack in, verified hardware IP out" can actually go.

If you're reading this to evaluate FreeJESD for real use: check the doc 06
build roadmap and the milestone status below before trusting any given
module, and don't assume a file is correct just because it exists — read
its header comment for verification status first.

## Features

- [ ] JESD204B subclass 0, 1, and 2 support (subclass 1 targeted for v0.1)
- [ ] Configurable number of lanes (L) and converters (M)
- [ ] TX and RX link layer state machines
- [ ] SYSREF handling for deterministic latency (subclass 1)
- [x] 8B/10B encoding/decoding
- [ ] ILAS (Initial Lane Alignment Sequence) generation and checking
- [ ] Synchronization and alignment logic
- [ ] APB/AXI4-Lite register map for configuration and status (stretch goal, post-v0.1)
- [x] Simulation testbenches (unit-level infrastructure + codec/scrambler tests so far)
- [ ] FPGA reference designs (Xilinx / Intel)

## Repository Structure

```
FreeJESD/
├── instructions/          # Spec pack the AI agent builds from (architecture,
│                           # protocol reference, module specs, verification
│                           # plan, coding guidelines, build roadmap)
├── rtl/
│   └── common/             # Shared modules (jesd_pkg, 8b/10b codec, scrambler/descrambler)
│                           # tx/ and rx/ link+transport layers land here as milestones complete
├── tb/
│   ├── common/             # Shared testbench macros (tb_pkg.sv)
│   ├── smoke/              # Toolchain smoke test
│   └── unit/                # Per-module self-checking testbenches
├── docs/                   # Generated docs: toolchain status, architecture notes
├── Makefile                # make test / make test_<name> / make lint / make clean
└── LICENSE, CONTRIBUTING.md
```

## Getting Started

### Prerequisites

- Icarus Verilog (`iverilog`/`vvp`), `-g2012` mode — the only simulator this
  project targets/tests against (see
  [instructions/05-CODING-AND-TOOLING-GUIDELINES.md](instructions/05-CODING-AND-TOOLING-GUIDELINES.md)
  for exactly which SystemVerilog subset is used and why)
- (Optional) Verilator, for `make lint` — skipped cleanly if not installed
- (Optional) Xilinx Vivado or Intel Quartus for FPGA synthesis, later

### Simulation

```bash
make test              # run the full testbench suite
make test_smoke        # run a single testbench, e.g. the toolchain smoke test
make clean
```

See [docs/TOOLCHAIN.md](docs/TOOLCHAIN.md) for the exact toolchain version
this has been verified against on the primary dev machine.

## Status

> **Early development, actively built milestone-by-milestone by an AI coding
> agent.** Milestones 0–1 (toolchain smoke test, shared package, 8b/10b
> codec, scrambler/descrambler) are implemented and passing under Icarus
> Verilog. See
> [instructions/06-BUILD-ROADMAP.md](instructions/06-BUILD-ROADMAP.md) for
> the full milestone list and exit criteria, and
> [docs/TOOLCHAIN.md](docs/TOOLCHAIN.md) for a running log of real bugs the
> testbenches have caught along the way. Contributions and feedback are
> welcome — including on the "AI wrote this" premise itself.

## Contributing

Contributions are welcome! Please open an issue or submit a pull request. See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

This project is licensed under the **CERN Open Hardware Licence Version 2 – Permissive (CERN-OHL-P v2)**. See [LICENSE](LICENSE) for details.

## References

- [JEDEC JESD204B Standard](https://www.jedec.org/standards-documents/docs/jesd204b)
- [ADI JESD204B Resources](https://wiki.analog.com/resources/tools-software/linux-drivers/jesd204)
