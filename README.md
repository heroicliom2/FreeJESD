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
- [ ] Configurable number of lanes (L) and converters (M) (single-lane working; multi-lane is Milestone 4)
- [x] Configurable internal datapath width — 16/32/64-bit (`DW_OCTETS` = 2/4/8), compile-time
      parameter threaded through the scrambler/descrambler/elastic buffer/RX datapath, so the
      core isn't locked to one converter bit width (e.g. 8/16/32-bit ADCs, F constrained to a
      multiple of the chosen width)
- [x] RX link layer state machine, single lane (`link_fsm.sv`: RESET->WAIT_FOR_PHY->CGS->ILAS->SYNCED, with fault re-entry)
- [ ] TX link layer state machine
- [ ] SYSREF handling for deterministic latency (subclass 1) (`lmfc_gen.sv` built; SYSREF-driven top-level integration is later)
- [x] 8B/10B encoding/decoding
- [x] ILAS (Initial Lane Alignment Sequence) generation and checking (RX side; TX-side `link_tx.sv` is Milestone 5)
- [x] Synchronization and alignment logic (`octet_align.sv`, `elastic_buffer.sv`, single lane)
- [ ] APB/AXI4-Lite register map for configuration and status (stretch goal, post-v0.1)
- [x] Simulation testbenches (unit-level infrastructure, codec/scrambler tests, golden-model TX
      generator, and a full RX-chain integration test driven by the golden model)
- [ ] FPGA reference designs (Xilinx / Intel)

## Repository Structure

```
FreeJESD/
├── instructions/          # Spec pack the AI agent builds from (architecture,
│                           # protocol reference, module specs, verification
│                           # plan, coding guidelines, build roadmap)
├── rtl/
│   └── common/             # Shared modules: jesd_pkg, 8b/10b codec, scrambler/descrambler,
│                           # single-lane RX link layer (octet_align, link_fsm, ilas_check,
│                           # elastic_buffer, lmfc_gen, datapath_rx)
│                           # tx/ and multi-lane rx/ land here as later milestones complete
├── tb/
│   ├── common/             # Shared testbench macros (tb_pkg.sv) + the
│   │                        # independent golden-model TX octet-stream generator
│   ├── smoke/              # Toolchain smoke test
│   ├── unit/                # Per-module self-checking testbenches
│   └── integration/         # Full-chain tests driven by the golden model (e.g. tb_datapath_rx.sv)
├── docs/                   # Toolchain status/bug log, agent handoff notes,
│                           # generated architecture notes
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

`iverilog`/`vvp`/`make` are on `PATH` on the primary dev machine already; see
[docs/TOOLCHAIN.md](docs/TOOLCHAIN.md) for the exact verified toolchain
version and machine-specific setup notes if you're setting up fresh.

## Status

> **Early development, actively built milestone-by-milestone by an AI coding
> agent.** Milestones 0–3 are implemented and passing under Icarus Verilog
> (10 testbenches, `make test`): toolchain smoke test, shared package
> (`jesd_pkg`, including the ILAS config-octet layout), 8b/10b codec,
> scrambler/descrambler, an independent golden-model TX octet-stream
> generator (CGS → 4-multiframe ILAS → scrambled user data), and a
> single-lane RX link layer (`octet_align`, `link_fsm`, `ilas_check`,
> `elastic_buffer`, `lmfc_gen`, wired together in `datapath_rx`) — verified
> end-to-end by driving the real RX chain with the golden model for both
> unscrambled and scrambled links, at all three supported datapath widths
> (16/32/64-bit). See
> [instructions/06-BUILD-ROADMAP.md](instructions/06-BUILD-ROADMAP.md) for
> the full milestone list and exit criteria,
> [docs/TOOLCHAIN.md](docs/TOOLCHAIN.md) for a running log of real bugs the
> testbenches have caught along the way, and
> [docs/HANDOFF.md](docs/HANDOFF.md) for the living "what a fresh session
> needs to know before continuing" notes — including several genuine design
> bugs (not just toolchain quirks) that full-chain integration testing
> caught but no individual module's own unit test did.
> Contributions and feedback are welcome — including on the "AI wrote this"
> premise itself.

## Contributing

Contributions are welcome! Please open an issue or submit a pull request. See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

This project is licensed under the **CERN Open Hardware Licence Version 2 – Permissive (CERN-OHL-P v2)**. See [LICENSE](LICENSE) for details.

## References

- [JEDEC JESD204B Standard](https://www.jedec.org/standards-documents/docs/jesd204b)
- [ADI JESD204B Resources](https://wiki.analog.com/resources/tools-software/linux-drivers/jesd204)
