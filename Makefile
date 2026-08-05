# FreeJESD — JESD204B Open-Source IP Core
# Makefile contract per instructions/04-VERIFICATION-PLAN.md:
#   make test            runs every tb/, aggregates pass/fail, nonzero exit on any failure
#   make test_<name>      e.g. make test_smoke — runs a single testbench
#   make lint              verilator --lint-only over rtl/ (skips cleanly if unavailable, doc 05)
#   make clean
#
# Each test target: iverilog -g2012 -o build/<name>.vvp <sources> && \
#   vvp build/<name>.vvp | tee build/<name>.log && \
#   ! grep -q "TESTBENCH FAILED" build/<name>.log
# The explicit grep is required even though tb_pkg.sv's `TB_FINISH also calls
# $fatal on failure: per doc 04, plain $finish after a manual error tally does
# not by itself set iverilog's process exit code, so the grep is the actual
# CI gate — don't remove it even if $fatal seems sufficient.

IVERILOG ?= iverilog
VVP      ?= vvp
VERILATOR ?= verilator
IFLAGS   := -g2012
BUILD    := build

TEST_LOGS :=

# define TEST_RULE,<name>,<source files>
# Registers build/<name>.vvp, build/<name>.log, and a `test_<name>` phony
# target, and appends the log to TEST_LOGS so `make test` picks it up.
define TEST_RULE
$(BUILD)/$(1).vvp: $(2) | $(BUILD)
	$(IVERILOG) $(IFLAGS) -o $$@ $(2)

$(BUILD)/$(1).log: $(BUILD)/$(1).vvp
	$(VVP) $$< | tee $$@
	@! grep -q "TESTBENCH FAILED" $$@

.PHONY: test_$(1)
test_$(1): $(BUILD)/$(1).log

TEST_LOGS += $(BUILD)/$(1).log
endef

# --- Milestone 0 ---
$(eval $(call TEST_RULE,smoke,tb/common/tb_pkg.sv tb/smoke/tb_smoke.sv))

# --- Milestone 1 ---
$(eval $(call TEST_RULE,8b10b,rtl/common/jesd_pkg.sv rtl/common/phy_8b10b_enc.sv rtl/common/phy_8b10b_dec.sv tb/common/tb_pkg.sv tb/unit/tb_phy_8b10b.sv))
$(eval $(call TEST_RULE,scrambler,rtl/common/jesd_pkg.sv rtl/common/scrambler.sv rtl/common/descrambler.sv tb/common/tb_pkg.sv tb/unit/tb_scrambler.sv))

# --- Milestone 2 ---
$(eval $(call TEST_RULE,golden_model,rtl/common/jesd_pkg.sv rtl/common/scrambler.sv rtl/common/descrambler.sv tb/common/tb_pkg.sv tb/common/jesd_golden_model.sv tb/unit/tb_golden_model.sv))

# --- Milestone 3 ---
$(eval $(call TEST_RULE,lmfc_gen,tb/common/tb_pkg.sv rtl/common/lmfc_gen.sv tb/unit/tb_lmfc_gen.sv))
$(eval $(call TEST_RULE,elastic_buffer,tb/common/tb_pkg.sv rtl/common/elastic_buffer.sv tb/unit/tb_elastic_buffer.sv))
$(eval $(call TEST_RULE,octet_align,rtl/common/jesd_pkg.sv tb/common/tb_pkg.sv rtl/common/octet_align.sv tb/unit/tb_octet_align.sv))
$(eval $(call TEST_RULE,link_fsm,rtl/common/jesd_pkg.sv tb/common/tb_pkg.sv rtl/common/link_fsm.sv tb/unit/tb_link_fsm.sv))
$(eval $(call TEST_RULE,ilas_check,rtl/common/jesd_pkg.sv tb/common/tb_pkg.sv rtl/common/ilas_check.sv tb/unit/tb_ilas_check.sv))
$(eval $(call TEST_RULE,datapath_rx,rtl/common/jesd_pkg.sv rtl/common/scrambler.sv rtl/common/descrambler.sv rtl/common/octet_align.sv rtl/common/link_fsm.sv rtl/common/ilas_check.sv rtl/common/elastic_buffer.sv rtl/common/lmfc_gen.sv rtl/common/datapath_rx.sv tb/common/tb_pkg.sv tb/common/jesd_golden_model.sv tb/integration/tb_datapath_rx.sv))

# --- Milestone 4 ---
$(eval $(call TEST_RULE,buffer_release,tb/common/tb_pkg.sv rtl/common/buffer_release.sv tb/unit/tb_buffer_release.sv))
$(eval $(call TEST_RULE,transport_rx,tb/common/tb_pkg.sv rtl/common/transport_rx.sv tb/unit/tb_transport_rx.sv))
$(eval $(call TEST_RULE,jesd204b_rx_top,rtl/common/jesd_pkg.sv rtl/common/scrambler.sv rtl/common/descrambler.sv rtl/common/octet_align.sv rtl/common/link_fsm.sv rtl/common/ilas_check.sv rtl/common/elastic_buffer.sv rtl/common/lmfc_gen.sv rtl/common/datapath_rx.sv rtl/common/buffer_release.sv rtl/common/transport_rx.sv rtl/common/jesd204b_rx_top.sv tb/common/tb_pkg.sv tb/common/jesd_golden_model.sv tb/integration/tb_jesd204b_rx_top.sv))
$(eval $(call TEST_RULE,multilane_skew,rtl/common/jesd_pkg.sv rtl/common/scrambler.sv rtl/common/descrambler.sv rtl/common/octet_align.sv rtl/common/link_fsm.sv rtl/common/ilas_check.sv rtl/common/elastic_buffer.sv rtl/common/lmfc_gen.sv rtl/common/datapath_rx.sv rtl/common/buffer_release.sv rtl/common/transport_rx.sv rtl/common/jesd204b_rx_top.sv tb/common/tb_pkg.sv tb/common/jesd_golden_model.sv tb/integration/tb_multilane_skew.sv))

# --- later milestones append more $(eval $(call TEST_RULE,...)) lines here,
#     one per tb/unit/tb_*.sv or tb/integration/tb_*.sv, per doc 06 ---

.PHONY: test
test: $(TEST_LOGS)
	@echo "All testbenches passed."

.PHONY: lint
lint:
	@if command -v $(VERILATOR) >/dev/null 2>&1; then \
		$(VERILATOR) --lint-only -Wall $(shell find rtl -name '*.sv') ; \
	else \
		echo "verilator not found on PATH — skipping lint (doc 05: skip rather than block)" ; \
	fi

$(BUILD):
	mkdir -p $(BUILD)

.PHONY: clean
clean:
	rm -rf $(BUILD)
