// SPDX-License-Identifier: CERN-OHL-P-2.0
// FreeJESD — JESD204B Open-Source IP Core
//
// Package: jesd_pkg
// Implements: instructions/03-MODULE-SPECS.md "jesd_pkg.sv" — shared K-char
// localparams, link FSM state enum, ilas checksum function, and the
// jesd_settings_t config struct used to parametrize every other module.
//
// ILAS config-octet field layout: doc 02 §3 lists the 14 fields (DID, BID,
// LID+ADJCNT/ADJDIR/PHADJ, SCR+L, F, K, M, N+CS, N'+SUBCLASSV, S+JESDV,
// HD+CF, RES x2, CHECKSUM) but does not give exact intra-octet bit offsets,
// and explicitly says to cross-check the real JEDEC text rather than trust a
// transcription — not available in this environment (see docs/HANDOFF.md,
// "Milestone 2 starting point"). Resolution: ilas_pack_config/
// ilas_unpack_config below define a self-consistent, documented,
// project-own layout (NOT the literal JEDEC Table 12 bit positions), used
// identically by tb_golden_model and (Milestone 3) ilas_check.sv/link_tx.sv
// — this is a single source of truth for both directions, verified by round
// trip in tb_golden_model, which is what actually matters for v0.1's
// documented non-goal of third-party PHY interop. ADJCNT/ADJDIR/PHADJ are
// dropped entirely (not used by any Subclass-1 deterministic-latency logic
// this project implements) rather than force-fit into a shrinking bit
// budget. Multi-bit fields whose real range starts at 1 (L, F, K, M, N, N',
// S) are stored as (value-1), a real JESD204B convention, so e.g. F=4 is
// stored as 3 — note this means a field's max real value (e.g. L=32) cannot
// round-trip through jesd_settings_t's narrower struct widths below (L is
// only 5 bits there); none of this project's target configs (doc 00) get
// close to those limits.
//
// Layout (13 octets + 1 checksum octet, LSB-first: octet 0 = bits[7:0]):
//   0: DID[7:0]                        1: BID[7:0]                 2: LID[7:0]
//   3: {SCR[7], 2'b00, (L-1)[4:0]}      4: (F-1)[7:0]                5: (K-1)[7:0]
//   6: (M-1)[7:0]                       7: {CS[7:6], 1'b0, (N-1)[4:0]}
//   8: {3'b001 (SUBCLASSV=1), (N'-1)[4:0]}   9: {3'b001 (JESDV=1), (S-1)[4:0]}
//   10: {HD[7], 2'b00, CF[4:0]}         11: RES=0                   12: RES=0
//   13: CHECKSUM = ilas_checksum(octets 0..12)

package jesd_pkg;

    // --- 8b/10b K-characters used by JESD204B (doc 02 §1) ---
    localparam logic [7:0] K_R = 8'h1C; // K28.0 - start of multiframe (ILAS mf0)
    localparam logic [7:0] K_A = 8'h7C; // K28.3 - lane alignment char (frame end in ILAS / char replacement)
    localparam logic [7:0] K_Q = 8'h9C; // K28.4 - start of ILAS mf1 (precedes config octets)
    localparam logic [7:0] K_K = 8'hBC; // K28.5 - code group sync (CGS) char
    localparam logic [7:0] K_F = 8'hFC; // K28.7 - frame alignment char (user-data frame end / char replacement)

    // --- Link bring-up FSM states (doc 02 §2), 5 states, fits state_o[2:0] ---
    typedef enum logic [2:0] {
        LINK_RESET       = 3'd0,
        LINK_WAIT_FOR_PHY = 3'd1,
        LINK_CGS         = 3'd2,
        LINK_ILAS        = 3'd3,
        LINK_SYNCED      = 3'd4
    } link_state_t;

    // --- Link configuration, used to parametrize RX/TX module instances.
    // Field widths are sized for internal use (not wire-exact ILAS packing —
    // see file header note above); doc 00's config table values fit
    // comfortably within these widths.
    typedef struct packed {
        logic [4:0] L;   // lanes per link (1..32)
        logic [7:0] F;   // octets per frame (1..256)
        logic [7:0] K;   // frames per multiframe (F*K must be mult-of-4, 17..1024)
        logic [7:0] M;   // converters per link
        logic [4:0] N;   // converter resolution, bits
        logic [4:0] Np;  // N' - octets-per-sample resolution, bits (N padded up to Np)
        logic [4:0] S;   // samples per converter per frame
        logic       SCR; // scrambling enable
        logic [1:0] CS;  // control bits per sample
        logic       HD;  // high density mode
        logic [4:0] CF;  // control words per frame clock period per link
    } jesd_settings_t;

    // ILAS config-octet checksum (doc 02 §3): sum mod 256 of the 13 octets
    // preceding the checksum octet. This part of doc 02 §3 is unambiguous and
    // does not depend on the intra-octet field layout noted above.
    //
    // Takes the 13 octets packed into a single 104-bit vector rather than an
    // unpacked array (`logic [7:0] octets[13]`, as doc 03 literally shows) —
    // iverilog does not support unpacked-dimension subroutine ports
    // ("Subroutine ports with unpacked dimensions are not yet supported",
    // confirmed against the actual installed toolchain). Octet 0 occupies
    // bits [7:0], octet 12 occupies bits [103:96].
    function automatic logic [7:0] ilas_checksum(input logic [103:0] octets);
        logic [7:0] sum;
        sum = 8'd0;
        for (int i = 0; i < 13; i++) begin
            sum = sum + octets[8*i +: 8];
        end
        return sum;
    endfunction

    // Packs the 13 non-checksum ILAS config octets per the layout above.
    // Plain scalar arguments (not a jesd_settings_t struct) deliberately —
    // passing packed struct types through function calls hit iverilog
    // quirks elsewhere in this project; scalars are the safer bet.
    // Returns octets 0..12 packed the same way ilas_checksum expects them
    // (octet 0 at bits[7:0]); caller appends ilas_checksum(...) as octet 13.
    function automatic logic [103:0] ilas_pack_config(
        input logic [7:0] did,
        input logic [7:0] bid,
        input logic [7:0] lid,
        input logic       scr,
        input logic [7:0] l_val,
        input logic [7:0] f_val,
        input logic [7:0] k_val,
        input logic [7:0] m_val,
        input logic [1:0] cs_val,
        input logic [7:0] n_val,
        input logic [7:0] np_val,
        input logic [7:0] s_val,
        input logic       hd,
        input logic [4:0] cf_val
    );
        logic [7:0] o0, o1, o2, o3, o4, o5, o6, o7, o8, o9, o10, o11, o12;
        o0  = did;
        o1  = bid;
        o2  = lid;
        o3  = {scr, 2'b00, (l_val[4:0] - 5'd1)};
        o4  = f_val - 8'd1;
        o5  = k_val - 8'd1;
        o6  = m_val - 8'd1;
        o7  = {cs_val, 1'b0, (n_val[4:0] - 5'd1)};
        o8  = {3'b001, (np_val[4:0] - 5'd1)}; // SUBCLASSV=1
        o9  = {3'b001, (s_val[4:0] - 5'd1)};  // JESDV=1
        o10 = {hd, 2'b00, cf_val};
        o11 = 8'h00;
        o12 = 8'h00;
        return {o12, o11, o10, o9, o8, o7, o6, o5, o4, o3, o2, o1, o0};
    endfunction

    // Reverse of ilas_pack_config. Returns all fields packed flat into one
    // 89-bit value (did[88:81], bid[80:73], lid[72:65], scr[64], l[63:56],
    // f[55:48], k[47:40], m[39:32], cs[31:30], n[29:22], np[21:14], s[13:6],
    // hd[5], cf[4:0]) rather than reconstructing a jesd_settings_t struct —
    // same struct-avoidance reasoning as ilas_pack_config. Caller slices the
    // fields it needs.
    function automatic logic [88:0] ilas_unpack_config(input logic [103:0] octets);
        logic [7:0] o0, o1, o2, o3, o4, o5, o6, o7, o8, o9, o10;
        logic [7:0] did, bid, lid, l_val, f_val, k_val, m_val, n_val, np_val, s_val;
        logic       scr, hd;
        logic [1:0] cs_val;
        logic [4:0] cf_val;
        o0  = octets[7:0];
        o1  = octets[15:8];
        o2  = octets[23:16];
        o3  = octets[31:24];
        o4  = octets[39:32];
        o5  = octets[47:40];
        o6  = octets[55:48];
        o7  = octets[63:56];
        o8  = octets[71:64];
        o9  = octets[79:72];
        o10 = octets[87:80];
        did    = o0;
        bid    = o1;
        lid    = o2;
        scr    = o3[7];
        l_val  = {3'b000, o3[4:0]} + 8'd1;
        f_val  = o4 + 8'd1;
        k_val  = o5 + 8'd1;
        m_val  = o6 + 8'd1;
        cs_val = o7[7:6];
        n_val  = {3'b000, o7[4:0]} + 8'd1;
        np_val = {3'b000, o8[4:0]} + 8'd1;
        s_val  = {3'b000, o9[4:0]} + 8'd1;
        hd     = o10[7];
        cf_val = o10[4:0];
        return {did, bid, lid, scr, l_val, f_val, k_val, m_val, cs_val, n_val, np_val, s_val, hd, cf_val};
    endfunction

endpackage
