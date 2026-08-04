# Contributing to FreeJESD

Thank you for your interest in contributing! FreeJESD is an open-source JESD204B IP core and welcomes contributions of all kinds — bug reports, documentation improvements, RTL code, testbenches, and FPGA reference designs.

## How to Contribute

### Reporting Bugs

Open an issue on GitHub and include:
- A clear description of the problem
- Steps to reproduce
- Expected vs. actual behavior
- Simulator/tool version

### Submitting Changes

1. Fork the repository and create a feature branch:
   ```bash
   git checkout -b feature/my-improvement
   ```
2. Make your changes following the coding style below.
3. Add or update simulation testbenches as appropriate.
4. Commit with a descriptive message.
5. Open a pull request against `main`.

## Coding Style

- **Language**: SystemVerilog (preferred) or Verilog-2001
- Use `logic` instead of `wire`/`reg` in SystemVerilog
- 4-space indentation, no tabs
- Module names in `snake_case`
- Signal names: active-low signals suffixed with `_n`
- Include a file header comment with module name, description, and author

## License

By contributing, you agree that your contributions will be licensed under the **CERN-OHL-P v2** license.
