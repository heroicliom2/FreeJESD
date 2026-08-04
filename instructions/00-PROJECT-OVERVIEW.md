# 00 — Project Overview

## What we're building

**OpenJESD204B** — a from-scratch, native Verilog/SystemVerilog implementation of the
JESD204B link layer + transport layer (Subclass 1), synthesizable and vendor-neutral
at the RTL boundary (a thin PHY adapter layer isolates SerDes/GTX-specific bits).

## Non-goals for v0.1 (explicitly out of scope)

- No PHY/SerDes implementation (8b/10b encode is in scope; the actual
  transceiver/CDR is vendor IP and stays outside this core, same assumption both
  reference repos make).
- No Subclass 0 or Subclass 2 support initially (Subclass 1, SYSREF-synchronized
  deterministic latency, is the target — matches both reference cores).
- No AXI4-Lite/CSR register file in v0.1 (parameters are RTL `parameter`s; a CSR
  wrapper can be layered on later the way LiteJESD204B's `LiteJESD204BCoreControl`
  does).
- No JESD204C (64b/66b) support.

## Deliverables

1. `rtl/` — synthesizable SystemVerilog (subset defined in doc 05), organized by
   layer (phy_adapter / link / transport / top).
2. `tb/` — self-checking testbenches, one per unit + one link-level integration TB,
   all runnable with plain `iverilog` + `vvp` (no vendor simulator, no UVM).
3. `Makefile` — `make test`, `make test_<module>`, `make clean`, `make lint`.
4. `docs/` — this spec pack plus a generated `ARCHITECTURE.md` reflecting what was
   actually built (kept in sync as source of truth diverges from plan).
5. CI-friendly: exit code 0 only if every self-check passes (no manual waveform
   inspection required to know pass/fail).

## Target configuration (v0.1 "must work" config)

Picked to match both reference repos' common ground and keep the first working
version small:

| Parameter | Value | Notes |
|---|---|---|
| Subclass | 1 | SYSREF-synchronized, deterministic latency |
| L (lanes/link) | 1, then 2, then 4 | Bring up single-lane first |
| F (octets/frame) | 4 (parametrizable 1–256 per spec) | |
| K (frames/multiframe) | 32 | Must satisfy `F*K` multiple-of-4 and 17 ≤ F*K ≤ 1024 (JESD204B constraint) |
| M (converters/link) | 2 | |
| N/N' (converter/sample resolution) | 16 / 16 | |
| Scrambling | Both modes (on/off), parametrized | LiteJESD supports; ListenToJESD paper flags "no unscrambled mode" as LiteJESD's gap — we support both from day one |
| Direction | RX first, TX second | RX is the harder/more valuable block (both repos prioritize RX; ListenToJESD is RX-only) |
| Data width | 32-bit internal datapath | Matches both repos' internal convention (4 octets/cycle) |

## Definition of done for v0.1

- RX core: locks through CGS → ILAS → user-data (SYNCED) against a self-generated
  golden-model TX stream, for 1/2/4 lanes, scrambled and unscrambled, with
  self-checking testbenches that report PASS/FAIL and exit nonzero on failure.
- TX core: produces a spec-compliant octet stream (CGS chars, ILAS multiframes with
  correct Lane/Multiframe Alignment Sequence contents, scrambled/unscrambled user
  data) that the RX core (or a reference checker) accepts.
- Fault injection tests: loss of CGS mid-link, corrupted ILAS field, lane
  misalignment/skew within and beyond buffer depth — all produce the documented
  FSM re-sync behavior, checked automatically.
- Everything runs via `make test` using only `iverilog`/`vvp`, no vendor tools.
