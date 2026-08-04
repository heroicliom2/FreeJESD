// SPDX-License-Identifier: CERN-OHL-P-2.0
// FreeJESD — JESD204B Open-Source IP Core
//
// Package: jesd_pkg
// Implements: instructions/03-MODULE-SPECS.md "jesd_pkg.sv" — shared K-char
// localparams, link FSM state enum, ilas checksum function, and the
// jesd_settings_t config struct used to parametrize every other module.
//
// NOTE on scope: this package intentionally does NOT include the ILAS
// configuration-octet bit-level pack/unpack functions mentioned in doc 03
// ("config-octet field packing/unpacking functions"). doc 02 §3 lists the 14
// ILAS config-octet fields (DID, BID, LID+ADJCNT/ADJDIR/PHADJ, SCR+L, F, K, M,
// N+CS, N'+SUBCLASSV, S+JESDV, HD+CF, RES x2, CHECKSUM) but does not give
// exact intra-octet bit offsets, and explicitly says to "implement exactly
// per spec table" / cross-check the JEDEC text directly rather than trust a
// transcription. That bit-exact layout is deferred to Milestone 2 (golden
// model) as a single source of truth shared by ilas_check.sv and link_tx.sv,
// to be pinned down (and flagged) at that point rather than guessed here.

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

endpackage
