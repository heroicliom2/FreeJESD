# FreeJESD

An open-source implementation of the **JESD204B** high-speed serial interface standard, written in synthesizable RTL (SystemVerilog/Verilog).

## Overview

JESD204B is a high-speed serial interface standard defined by JEDEC, widely used to connect data converters (ADCs/DACs) to FPGAs and ASICs. FreeJESD provides a fully open, portable, and vendor-agnostic implementation of the JESD204B link layer.

## Features

- [ ] JESD204B subclass 0, 1, and 2 support
- [ ] Configurable number of lanes (L) and converters (M)
- [ ] TX and RX link layer state machines
- [ ] SYSREF handling for deterministic latency (subclass 1)
- [ ] 8B/10B encoding/decoding
- [ ] ILAS (Initial Lane Alignment Sequence) generation and checking
- [ ] Synchronization and alignment logic
- [ ] APB/AXI4-Lite register map for configuration and status
- [ ] Simulation testbenches
- [ ] FPGA reference designs (Xilinx / Intel)

## Repository Structure

```
FreeJESD/
├── rtl/                  # Synthesizable RTL source files
│   ├── tx/               # Transmit path
│   └── rx/               # Receive path
├── tb/                   # Simulation testbenches
├── doc/                  # Documentation and specifications
├── scripts/              # Simulation and synthesis scripts
└── fpga/                 # FPGA reference designs
```

## Getting Started

### Prerequisites

- A SystemVerilog-capable simulator (e.g., ModelSim, Verilator, Icarus Verilog)
- (Optional) Xilinx Vivado or Intel Quartus for FPGA synthesis

### Simulation

```bash
# Example using Icarus Verilog (once source files are available)
cd tb
iverilog -g2012 -o sim_top sim_top.sv
vvp sim_top
```

## Status

> **Early development.** RTL sources are being actively developed. Contributions and feedback are welcome.

## Contributing

Contributions are welcome! Please open an issue or submit a pull request. See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

This project is licensed under the **CERN Open Hardware Licence Version 2 – Permissive (CERN-OHL-P v2)**. See [LICENSE](LICENSE) for details.

## References

- [JEDEC JESD204B Standard](https://www.jedec.org/standards-documents/docs/jesd204b)
- [ADI JESD204B Resources](https://wiki.analog.com/resources/tools-software/linux-drivers/jesd204)
