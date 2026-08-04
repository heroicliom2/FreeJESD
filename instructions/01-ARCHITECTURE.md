# 01 — Architecture

## Layering (both reference cores agree on this split)

```
            ┌─────────────────────────────────────────────────────────┐
            │                      TRANSPORT LAYER                     │
            │   converter <-> lane mapping (sample <-> octet framing)  │
            └─────────────────────────────────────────────────────────┘
                                     │  per-lane 32-bit octet stream
            ┌─────────────────────────────────────────────────────────┐
            │                         LINK LAYER                       │
            │  per lane: CGS · ILAS · (de)scrambler · elastic buffer   │
            │  shared:   LMFC generator · lane deskew / SYNC~ handling │
            └─────────────────────────────────────────────────────────┘
                                     │  8b/10b symbols (or decoded octets)
            ┌─────────────────────────────────────────────────────────┐
            │                    PHY ADAPTER (thin)                    │
            │   8b/10b enc/dec, comma detect hooks — NOT the SerDes    │
            └─────────────────────────────────────────────────────────┘
```

This mirrors LiteJESD204B's `transport.py` / `link.py` / PHY split, and matches
ListenToJESD204B's description of `data_path` (link-layer, per lane) feeding a
transport-level reassembly stage.

## Top-level block diagram (RX direction, v0.1 priority)

```
        ┌────────┐  ┌────────┐        ┌────────┐
lane0 ->│ phy_adp│->│datapath│---┐    │        │
        └────────┘  │  (CGS, │   |    │        │
        ┌────────┐  │  ILAS, │   |    │        │
lane1 ->│ phy_adp│->│descram,│---+--->│transport│--> converter0..M-1
        └────────┘  │ elastic│   |    │  _rx    │    (AXI-Stream-like)
          ...       │ buffer)│   |    │        │
        ┌────────┐  └────────┘   |    │        │
laneL-1->│ phy_adp│->│  ...  │---┘    │        │
        └────────┘  └────────┘        └────────┘
                          ^                 ^
                          |                 |
                    ┌──────────┐      ┌──────────┐
                    │   LMFC   │      │  buffer_ │
                    │generator │----->│ release  │
                    │(SYSREF-  │      │(deskew   │
                    │ locked)  │      │ across   │
                    └──────────┘      │  lanes)  │
                          ^           └──────────┘
                       jref (SYSREF, resync'd to sys clock)
```

Per-lane `link_fsm` (5-state, from ListenToJESD204B's documented design) drives
`datapath` per lane; `buffer_release`/skew handling (LiteJESD204B's `skew_fifo` +
`Reduce("AND", ...)` on `link.ready`) is the shared cross-lane sync point.

## Module inventory

| Module | Layer | Role | Primary reference |
|---|---|---|---|
| `jesd_pkg.sv` | — | Shared params/typedefs/functions (K28.5 etc.) | both |
| `phy_8b10b_dec.sv` / `_enc.sv` | PHY adapter | 8b/10b codec + comma detect | both (external in real designs, but needed here for full sim) |
| `octet_align.sv` | Link (per lane) | Rotates/aligns incoming word to K28.5 comma | ListenToJESD204B `octet_align` |
| `link_fsm.sv` | Link (per lane) | 5-state CGS/ILAS/SYNCED control FSM | ListenToJESD204B control FSM |
| `ilas_check.sv` | Link (per lane) | Extracts + validates ILAS config octets (Lane/Multiframe Alignment Sequence, checksum) | both |
| `scrambler.sv` / `descrambler.sv` | Link (per lane) | Self-synchronous LFSR, `G(x) = x^15+x^14+1` (JESD204B poly; note ListenToJESD204B paper's is a typo/variant, see doc 02) | both |
| `elastic_buffer.sv` | Link (per lane) | Circular FIFO absorbing inter-lane skew, released on LMFC boundary | both |
| `lmfc_gen.sv` | Link (shared) | SYSREF-synchronized local multiframe counter | both (`LMFC` class in LiteJESD204B, "SYSREF-Synchronized LMFC Generation" in ListenToJESD204B) |
| `buffer_release.sv` | Link (shared) | Cross-lane AND of per-lane ready + simultaneous release | ListenToJESD204B `buffer_release`, LiteJESD204B `Reduce("AND", ...)` |
| `datapath_rx.sv` | Link (per lane, wrapper) | Wires octet_align+link_fsm+ilas_check+descrambler+elastic_buffer | ListenToJESD204B `data_path` |
| `transport_rx.sv` | Transport | Lane→converter octet reassembly per F/K/M mapping | LiteJESD204B `transport.py` |
| `transport_tx.sv` | Transport | Converter→lane octet mapping (mirror) | LiteJESD204B `transport.py` |
| `link_tx.sv` | Link | Per-lane TX: scrambler + ILAS/CGS sequence generator + framing | LiteJESD204B `link.py` (TX side) |
| `jesd204b_rx_top.sv` | Top | Instantiates N lanes of datapath_rx + shared lmfc/buffer_release + transport_rx | LiteJESD204B `LiteJESD204BCoreRX` |
| `jesd204b_tx_top.sv` | Top | Instantiates N lanes of link_tx + transport_tx + lmfc | LiteJESD204B `LiteJESD204BCoreTX` |
| `stpl_gen.sv` / `stpl_checker.sv` | Test infra | Standard test-pattern self-test, built into core like LiteJESD204B's `LiteJESD204BSTPLGenerator/Checker` | LiteJESD204B |

## Clock domain policy

Follow ListenToJESD204B's explicit simplification for v0.1: **single clock domain**
for all link/transport logic (`jesd_clk`), matching their "Unified Clocking: all
internal logic driven by a single clock to avoid CDC issues" design choice. SYSREF
and any PHY-domain signals are resynchronized with a 2-flop `MultiReg`-style
synchronizer at the boundary. LiteJESD204B's more complex `CDC`/`ElasticBuffer`
classes (crossing from PHY's own clock domain into `jesd`) are documented as a v0.2
stretch goal, not required for v0.1 — this keeps the first testbenches free of
async-domain race conditions, which matters a lot for a deterministic, iverilog-only
self-checking flow.

## Interface convention

Use a plain, iverilog-safe streaming convention (avoid `interface`/`modport` — see
doc 05) of `valid`/`data`/`ctrl` signal triplets per lane, e.g.:

```systemverilog
output logic        m_valid,
output logic [31:0] m_data,   // 4 octets/cycle
output logic [3:0]  m_ctrl,   // 1 ctrl bit per octet: 1 = K-character
input  logic         s_ready  // present for future backpressure; both refs
                                // assume continuous consumption in v0.1 (no ready
                                // stall in the datapath itself), same as
                                // ListenToJESD204B's documented "does not support
                                // backpressure via tready"
```
