# OpenJESD204B — Spec Pack for Agentic Implementation

This folder is a set of specification documents meant to be read by a **Claude Code
agent** (or any coding agent) to generate an original, open-source **JESD204B IP core
in synthesizable Verilog/SystemVerilog**, with a **self-checking testbench that runs
under Icarus Verilog (`iverilog`/`vvp`)**.

## Provenance / why these docs exist

This project is *architecturally inspired by* two existing open-source cores, but the
RTL itself is to be written from scratch against the JESD204B (JEDEC JESD204B.01,
Jul 2011) specification — not transcribed or copy-pasted from either repo:

- **[enjoy-digital/litejesd204b](https://github.com/enjoy-digital/litejesd204b)**
  (BSD-2-Clause) — Python/Migen generator, TX+RX, full transport/link/PHY split,
  LMFC generator, CDC, skew-FIFO based lane deskew, CSR control layer, STPL
  (standard test pattern) self-test generator/checker built into the core itself.
- **[pulp-bio/ListenToJESD](https://github.com/pulp-bio/ListenToJESD)**
  (Solderpad-0.51) — hand-written SystemVerilog, RX-only, 5-state link FSM
  (RESET → WAIT_FOR_PHY → CGS → ILAS → SYNCED), per-lane `data_path` module
  encapsulating CGS+ILAS+descramble+elastic-buffer, SYSREF-locked LMFC,
  documented in their IWASI 2025 paper (arXiv:2508.14798).

Both are permissively licensed and license-compatible with each other; the plan
below borrows **architecture and verification methodology**, not code, and adds one
thing neither repo has: a **portable, iverilog-runnable, self-checking testbench
suite** (both repos rely on Vivado/vendor-specific sim flows).

## Reading order for the agent

1. `00-PROJECT-OVERVIEW.md` — scope, license, definition of done for v0.1
2. `01-ARCHITECTURE.md` — block diagram, layering, module list, clock domains
3. `02-PROTOCOL-REFERENCE.md` — the JESD204B mechanics every module must implement
4. `03-MODULE-SPECS.md` — per-module port lists, parameters, FSMs, pseudocode
5. `04-VERIFICATION-PLAN.md` — self-checking TB architecture, directory layout, Makefile targets
6. `05-CODING-AND-TOOLING-GUIDELINES.md` — the iverilog-safe SV subset, lint rules, style
7. `06-BUILD-ROADMAP.md` — ordered task list / milestones with exit criteria per step

## How to use this with Claude Code

Point the agent at this folder and ask it to work through `06-BUILD-ROADMAP.md`
milestone by milestone, re-reading the relevant module spec section before writing
each file, and running the milestone's testbench with `iverilog`/`vvp` before moving
on. Suggested first prompt to Claude Code:

```
Read all files in jesd204b-spec/ in the order listed in README.md.
Then implement Milestone 0 and Milestone 1 from 06-BUILD-ROADMAP.md,
following 05-CODING-AND-TOOLING-GUIDELINES.md strictly. Run the
testbenches with iverilog before reporting done.
```

## License plan for the new IP

Recommend **Apache-2.0** or **Solderpad-0.51** (Solderpad = Apache-2.0 + explicit
hardware patent language, common for open silicon). Either is compatible with both
source repos' licenses (BSD-2, Solderpad-0.51). Do not copy code verbatim from
either repo; keep a `THIRD_PARTY_NOTICES.md` crediting both as architectural
references.
