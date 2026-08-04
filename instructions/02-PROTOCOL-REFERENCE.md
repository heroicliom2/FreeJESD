# 02 — JESD204B Protocol Reference (what the RTL must implement)

This is a working reference, not a copy of the JEDEC spec text. Agents should treat
JESD204B.01 (JEDEC, Jul 2011) as the normative source for anything ambiguous below;
this doc captures the mechanics both reference repos actually implement, which is
the practical subset needed for interop.

## 1. Special characters (8b/10b K-characters used by JESD204B)

| Symbol | K-char | Octet value | Meaning |
|---|---|---|---|
| `/R/` | K28.0 | 0x1C | Start of multiframe (first char of ILAS multiframe 0) |
| `/A/` | K28.3 | 0x7C | Lane alignment character (end of each frame within an ILAS multiframe, or replacing repeated data in scrambled user data per JESD204B "character replacement" rule) |
| `/Q/` | K28.4 | 0x9C | Start of 2nd ILAS multiframe — precedes configuration octets 0–3 |
| `/K/` | K28.5 | 0xBC | Code group sync character (CGS) |
| `/F/` | K28.7 | 0xFC | Frame alignment character (end of frame in user data, or replacing repeated data at frame boundary — "F/A character replacement") |

`link_fsm`/`octet_align` must recognize these via their decoded 8-bit value + the
"K" control bit produced by the 8b/10b decoder, not by re-deriving from raw 10-bit
symbols.

## 2. Link bring-up sequence (state machine both repos implement)

```
RESET -> WAIT_FOR_PHY -> CGS -> ILAS -> SYNCED
                            ^      |
                            └──────┘ (fault: re-enter CGS)
```

- **WAIT_FOR_PHY**: wait for PHY-level lock (word/comma alignment, `rx_align`
  hook, per LiteJESD204B `phy.rx_align`).
- **CGS**: transmitter and receiver exchange `/K/` (K28.5) characters.
  Receiver asserts `SYNC~` low (JESD204B `SYNC~` is active-low; internally model as
  `sync_n` per LiteJESD204B's CSR field naming) once it has detected N consecutive
  `/K/` characters aligned across all lanes (per-lane detection, `sync_n` released
  per-link only when **all** lanes are aligned — this is the cross-lane AND point).
  A stability counter (configurable threshold, default e.g. 4 consecutive) gates the
  CGS→ILAS transition to avoid false locks on transient comma-like data, matching
  ListenToJESD204B's "stability flag and cycle counter gate state transitions."
- **ILAS** (Initial Lane Alignment Sequence): exactly **4 multiframes**, each
  `F*K` octets long, sent by the transmitter after CGS release:
  - Multiframe 0: starts with `/R/` (K28.0), each frame within it ends with `/A/`
    (K28.3), used purely for lane alignment (no meaningful payload).
  - Multiframe 1: starts with `/R/` then `/Q/` (K28.4), followed by **configuration
    octets 0–13** (link parameters: DID, BID, LID, L, SCR, F, K, M, N, CS, N', S,
    CF, plus a checksum octet — see §3), padded with `/A/`-terminated frames to fill
    out `F*K` octets, matching the JESD204B Table "Configuration Data" layout.
  - Multiframes 2–3: same structure as multiframe 0 (alignment only).
  - Every multiframe ends its last frame with `/A/`.
- **ILAS validation** (`ilas_check`): receiver decodes the configuration octets from
  multiframe 1 and compares against its own configured L/F/K/M/N/N'/SCR/S/CF
  parameters (or just logs them, per `ilas_check` enable flag — LiteJESD204B exposes
  this as a runtime-disableable CSR bit `ilas_check_disable`; keep it as a
  compile-time or runtime `ilas_check_en` port here). Checksum mismatch or parameter
  mismatch → do not transition to SYNCED, re-enter CGS (fault path).
- **SYNCED**: user data flows. Receiver deasserts CGS request; from here on scrambled
  (if `SCR=1`) octet stream, frame-aligned by `/F/` markers (if inserted; when
  scrambling is on and data would otherwise repeat, `/F/`/`/A/` character
  replacement is used at frame/multiframe boundaries per spec §5.3.3.4.4 — v0.1 can
  implement the simple “always insert alignment chars, receiver strips them”
  behavior first and treat full character-replacement-on-repeat as a v0.2 refinement,
  documenting the simplification explicitly in code comments).

## 3. ILAS configuration octets (multiframe 1, after `/R/ /Q/`)

14 octets, bit-packed per JESD204B Table 12 (implement exactly per spec table —
summarized field list for the module spec to reference):

`DID, BID, LID(+ADJCNT/ADJDIR/PHADJ bits), SCR+L, F, K, M, N(+CS), N'(+SUBCLASSV),
S(+JESDV), HD(+CF), RES(x2), CHECKSUM`

The **checksum** is the sum (mod 256) of the preceding 13 octets — compute and
compare exactly this way; it's the cheapest, highest-value correctness check for
the self-checking testbench (mismatched checksum = an immediately falsifiable
assertion).

## 4. Scrambler / descrambler

Self-synchronous, additive scrambler, polynomial **G(x) = x¹⁵ + x¹⁴ + 1** per
JESD204B §5.2.3 (verify against the JEDEC spec text directly when implementing —
one of the two reference papers describes a differently-indexed polynomial, which
looks like it may reflect a project-specific variant or a transcription artifact;
do not copy that value without cross-checking the standard). Key properties to
encode as self-checks:

- Applied only to the **user-data phase**, never to CGS or ILAS octets (both repos
  agree: "Scrambling does not affect link initialization in CGS/ILAS phases").
- Self-synchronizing: descrambler needs no explicit sync signal, only the scrambled
  stream itself — a strong property to test directly (feed scrambled data into
  descrambler mid-stream with no special reset, confirm correct output after LFSR
  fills, i.e. after 15 octets of latency).
- `scramble(descramble(x)) == x` and `descramble(scramble(x)) == x` — use this as a
  direct self-checking testbench property (see doc 04) independent of the rest of
  the protocol stack.

## 5. LMFC (Local Multiframe Clock)

- A free-running counter, `F*K` octets period, whose **phase is set by SYSREF**
  (`jref` in LiteJESD204B naming): on the SYSREF rising edge the counter reloads to
  a fixed offset (`load` parameter — LiteJESD204B uses `load=(1+ebuf_latency)` for
  TX and the negative for RX to compensate pipeline latency; document your own
  core's actual pipeline depth here once implemented, don't hardcode the reference
  repos' numbers since your pipeline will differ).
- LMFC-zero pulse is used as the release trigger for elastic buffers (deterministic
  latency mechanism of Subclass 1) — see §6.

## 6. Elastic buffer / lane deskew

- Each lane has a small circular-buffer FIFO. Data is written continuously once a
  lane reaches SYNCED; **all lanes' buffers are read out together, gated by the
  LMFC-zero pulse**, only once *every* lane in the link is SYNCED (cross-lane AND —
  `Reduce("AND", [link.ready ...])` in LiteJESD204B, `buffer_release` module in
  ListenToJESD204B).
- Buffer depth must be ≥ max expected inter-lane skew (configurable parameter);
  exceeding it is a real fault condition the self-checking TB should exercise
  (inject a lane delay larger than buffer depth and confirm the core reports
  a defined error state rather than silently corrupting data).

## 7. Transport layer (converter ↔ lane mapping)

Given `L` lanes, `M` converters, `F` octets/frame, `S` samples/converter/frame,
`N'` octets/sample: the transport layer's job is purely a deterministic
octet-interleave/de-interleave between the per-lane 8b/10b octet streams and the
per-converter sample streams, per the JESD204B "coarse" then "fine" mapping
tables. Implement as a lookup/generate-loop parametrized by `L,M,F,S,N'` rather
than hand-coding fixed cases — this is the part of the design most worth writing a
directed, table-driven testbench for (feed known converter sample values in,
check exact octet positions out, and the inverse), since off-by-one octet mapping
bugs are the single most common JESD204B implementation error in practice.
