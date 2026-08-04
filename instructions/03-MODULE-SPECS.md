# 03 — Module Specs

Conventions: all modules single-clock (`clk`), active-high sync `rst`, 32-bit /
4-octet-per-cycle datapath (§01). Ports use the `valid/data/ctrl` streaming
convention from doc 01 unless noted. Every module below should get its own unit
testbench per doc 04 before being wired into `datapath_rx`/`link_tx`.

---

## `jesd_pkg.sv`
Shared package: K-char localparams (`K_R=8'h1C, K_A=8'h7C, K_Q=8'h9C, K_K=8'hBC,
K_F=8'hFC`), FSM state enum, config-octet field packing/unpacking functions
(`ilas_checksum(bit [7:0] octets[13])` etc.), and a `jesd_settings_t` struct
(`L, F, K, M, N, Np, S, SCR, CS, HD, CF`) used to parametrize instances.

---

## `phy_8b10b_dec.sv` / `phy_8b10b_enc.sv`
- **Params:** none
- **Ports (dec):** `in [9:0] symbol_i`, `out [7:0] data_o`, `out is_k_o`,
  `out disp_err_o`, `out code_err_o`, `inout bit running_disparity` (or expose as
  a register + `disp_o` status).
- **Behavior:** standard 8b/10b tables (5b/6b + 3b/4b), running disparity tracked
  internally. This is well-trodden logic — implement from the standard 8b/10b
  encode/decode tables directly (not protocol-specific), and unit-test against a
  small canonical vector set (all D-characters round-trip, all valid K-characters
  decode correctly, invalid codes flagged via `code_err_o`).

---

## `octet_align.sv`
- **Params:** `LANES=1` (kept per-lane; instantiate once per lane)
- **Ports:** `in [9:0] symbol_i` (or `[7:0]+is_k` if fed post-8b10b), `out [7:0]
  data_o`, `out is_k_o`, `out aligned_o`
- **Behavior:** search incoming stream for `K_K` (K28.5); once found, latch the
  bit/word rotation needed so `K_K` lands at a fixed octet position; assert
  `aligned_o` once alignment is stable for N consecutive commas (configurable,
  default 4, mirroring the CGS stability-counter idea). Re-run alignment search if
  commas stop appearing where expected (loss of alignment fault).

---

## `link_fsm.sv` (per lane)
- **Params:** `CGS_STABLE_CNT=4`, `MAX_FAULT_CNT` (threshold before re-sync)
- **Ports:** `in aligned_i`, `in [7:0] data_i`, `in is_k_i`, `in ilas_valid_i`
  (from `ilas_check`), `in ilas_done_i`, `out sync_n_o` (this lane's SYNC~
  request), `out [2:0] state_o` (RESET/WAIT_PHY/CGS/ILAS/SYNCED, for
  observability/debug and for the TB to assert against directly), `out lane_ready_o`
- **Behavior:** implements the 5-state FSM from doc 02 §2. Expose `state_o` so
  the self-checking TB can assert exact state-transition sequences, not just final
  pass/fail — this is the single highest-value signal for verification (see doc 04).

---

## `ilas_check.sv` (per lane)
- **Params:** expected `jesd_settings_t` (from `jesd_pkg`)
- **Ports:** `in [7:0] data_i`, `in is_k_i`, `in [1:0] mf_index_i` (which of the 4
  ILAS multiframes, driven by link_fsm/counter), `in enable_i` (runtime
  check-disable, like LiteJESD204B's `ilas_check`), `out cfg_valid_o`,
  `out [111:0] cfg_octets_o` (raw 14 captured octets, for TB introspection),
  `out checksum_err_o`, `out param_mismatch_o`
- **Behavior:** on multiframe index 1, after seeing `/R/ /Q/`, capture the next 14
  octets, compute checksum per doc 02 §3, compare against expected settings if
  `enable_i`. When `enable_i=0`, always report `cfg_valid_o=1` after capture
  (observe-only mode).

---

## `scrambler.sv` / `descrambler.sv`
- **Params:** `POLY` (default per doc 02 §4, but keep parametrized so the unit TB
  can also test smaller/toy polynomials for LFSR-correctness debugging)
- **Ports:** `in valid_i`, `in [31:0] data_i`, `in [3:0] ctrl_i` (K-char mask;
  scrambler must pass K-chars through **unscrambled**), `in enable_i`,
  `out valid_o`, `out [31:0] data_o`, `out [3:0] ctrl_o`
- **Behavior:** self-synchronous multiplicative/additive LFSR per doc 02 §4,
  processing 4 octets/cycle (parallelized LFSR — implement via the standard
  "unroll N serial shifts into one combinational block" technique, don't try to
  do 4 serial single-bit shifts across 4 cycles). `enable_i=0` ⇒ pure passthrough.
  K-characters (where `ctrl_i[i]=1`) must never be scrambled — pass those octet
  lanes through unmodified while still advancing internal LFSR state only on
  non-K octets (match spec behavior exactly; this is a common bug source).

---

## `lmfc_gen.sv`
- **Params:** `LMFC_CYCLES` (= `F*K`), `LOAD_OFFSET` (signed, pipeline-latency
  compensation — see doc 02 §5)
- **Ports:** `in sysref_i` (already resynchronized to `clk` upstream), `out
  [$clog2(LMFC_CYCLES)-1:0] count_o`, `out zero_o`
- **Behavior:** counter free-runs, reloads to `LOAD_OFFSET mod LMFC_CYCLES` on
  `sysref_i` rising edge (edge-detected internally, 2-FF delay same as
  LiteJESD204B's `LMFC` class), `zero_o` pulses when `count_o==0`.

---

## `elastic_buffer.sv` (per lane)
- **Params:** `DEPTH` (≥ max tolerated skew, power-of-2 for a simple circular
  buffer)
- **Ports:** `in wr_valid_i`, `in [31:0] wr_data_i`, `in lane_ready_i` (from
  link_fsm, gates write-enable), `in release_i` (from shared `buffer_release`,
  gates read), `out [31:0] rd_data_o`, `out rd_valid_o`, `out [DEPTHBITS:0]
  level_o` (fill level, for skew-fault detection), `out overflow_o`,
  `out underflow_o`
- **Behavior:** simple circular FIFO; `overflow_o`/`underflow_o` are hard faults
  the TB checks are never asserted in nominal tests, and *are* asserted in the
  directed skew-overflow fault test (doc 04).

---

## `buffer_release.sv` (shared, one per link)
- **Ports:** `in [LANES-1:0] lane_ready_i`, `in lmfc_zero_i`, `out release_o`
- **Behavior:** `release_o = &lane_ready_i` qualified by `lmfc_zero_i` — pure
  combinational/1-cycle-registered AND-reduce + edge gate, matching
  LiteJESD204B's `Reduce("AND", [link.ready for link in links])` gated by
  `lmfc.zero`.

---

## `datapath_rx.sv` (per lane, structural wrapper)
Wires `octet_align → link_fsm ⇄ ilas_check → descrambler → elastic_buffer`
per ListenToJESD204B's `data_path` module description (CGS/ILAS encapsulated
per-lane, descramble + elastic buffer per-lane, deskew is the shared top-level
job). Exposes the per-lane `state_o`, `lane_ready_o`, fault flags upward for
top-level fault-OR and for the TB to probe directly.

---

## `transport_rx.sv`
- **Params:** `jesd_settings_t` (`L,M,F,S,Np`)
- **Ports:** `in [31:0] lane_data_i [L]`, `in lane_valid_i [L]`, `out [Np*8-1:0]
  converter_data_o [M]`, `out converter_valid_o`
- **Behavior:** deterministic octet de-interleave per doc 02 §7. Implement with a
  `generate`/function-based lookup (`octet_source(lane, octet_index) -> (converter,
  sample, byte_index)` per the JESD204B mapping tables) rather than hand-unrolled
  per-config cases, so changing `L/M/F/S` doesn't require new code.

---

## `link_tx.sv`, `transport_tx.sv`
Mirror of the RX chain: transport_tx interleaves converter samples into per-lane
octets; link_tx per lane generates CGS `/K/` characters, then the 4-multiframe
ILAS sequence (with correctly computed config octets + checksum), then scrambled
(if enabled) user data with `/F//A/` alignment character insertion. Reuse
`scrambler.sv` (encode direction) and the same `jesd_pkg` config-octet
packing function used by `ilas_check` (single source of truth for the ILAS
octet layout, so TX and RX can't disagree on the field layout).

---

## `jesd204b_rx_top.sv` / `jesd204b_tx_top.sv`
Instantiate `L` lanes of `datapath_rx`/`link_tx`, one `lmfc_gen`, one
`buffer_release` (RX only), one `transport_rx`/`transport_tx`. Top-level ports:
per-lane PHY-facing octet/K streams, `sysref_i`, `enable_i`, aggregated
`ready_o`/`sync_n_o`, converter-facing sample ports. This is the DUT for the
link-level integration testbench (doc 04).

---

## `stpl_gen.sv` / `stpl_checker.sv`
Standard test pattern generator/checker (JESD204B Annex — a fixed
LFSR-based per-converter pattern used for interop testing), same purpose as
LiteJESD204B's `LiteJESD204BSTPLGenerator/Checker`: lets the integration
testbench validate the full RX (or TX) core end-to-end against a known pattern
without needing a full external ADC/DAC model.
