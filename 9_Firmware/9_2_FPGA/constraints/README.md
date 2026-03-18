# AERIS-10 FPGA Constraint Files

## Three Targets

| File | Device | Package | Purpose |
|------|--------|---------|---------|
| `xc7a50t_ftg256.xdc` | XC7A50T-2FTG256I | FTG256 (256-ball BGA) | Upstream author's board (copy of `cntrt.xdc`) |
| `xc7a200t_fbg484.xdc` | XC7A200T-2FBG484I | FBG484 (484-ball BGA) | Production board (new PCB design) |
| `te0712_te0701_minimal.xdc` | XC7A200T-2FBG484I | FBG484 (484-ball BGA) | Trenz dev split target (minimal clock/reset + LEDs/status) |

## Why Three Files

The upstream prototype uses a smaller XC7A50T in an FTG256 package. The production
AERIS-10 radar migrates to the XC7A200T for more logic, BRAM, and DSP resources.
The two devices have completely different packages and pin names, so each needs its
own constraint file.

The Trenz TE0712/TE0701 path uses the same FPGA part as production but different board
pinout and peripherals. The dev target is split into its own top wrapper
(`radar_system_top_te0712_dev.v`) and minimal constraints file to avoid accidental mixing
of production pin assignments during bring-up.

## Bank Voltage Assignments

### XC7A50T-FTG256 (Upstream)

| Bank | VCCO | Signals |
|------|------|---------|
| 0 | 3.3V | JTAG, flash CS |
| 14 | 3.3V | ADC LVDS (LVDS_33), SPI flash |
| 15 | 3.3V | DAC, clocks, STM32 3.3V SPI, DIG bus |
| 34 | 1.8V | ADAR1000 control, SPI 1.8V side |
| 35 | 3.3V | Unused (no signal connections) |

### XC7A200T-FBG484 (Production)

| Bank | VCCO | Used/Avail | Signals |
|------|------|------------|---------|
| 13 | 3.3V | 17/35 | Debug overflow (doppler bins, range bins, status) |
| 14 | 2.5V | 19/50 | ADC LVDS_25 + DIFF_TERM, ADC power-down |
| 15 | 3.3V | 27/50 | System clocks (100M, 120M), DAC, RF, STM32 3.3V SPI, DIG bus |
| 16 | 3.3V | 50/50 | FT601 USB 3.0 (32-bit data + byte enable + control) |
| 34 | 1.8V | 19/50 | ADAR1000 beamformer control, SPI 1.8V side |
| 35 | 3.3V | 50/50 | Status outputs (beam position, chirp, doppler data bus) |

## Signal Differences Between Targets

| Signal | Upstream (FTG256) | Production (FBG484) |
|--------|-------------------|---------------------|
| FT601 USB | Unwired (chip placed, no nets) | Fully wired, Bank 16 |
| `dac_clk` | Not connected (DAC clocked by AD9523 directly) | Routed, FPGA drives DAC |
| `ft601_be` width | `[1:0]` in upstream RTL | `[3:0]` (RTL updated) |
| ADC LVDS standard | LVDS_33 (3.3V bank) | LVDS_25 (2.5V bank, better quality) |
| Status/debug outputs | No physical pins (commented out) | All routed to Banks 35 + 13 |

## How to Select in Vivado

In the Vivado project, only one target XDC should be active at a time:

1. Add both files to the project: `File > Add Sources > Add Constraints`
2. In the Sources panel, right-click the XDC you do NOT want and select
   `Set File Properties > Enabled = false` (or remove it from the active
   constraint set)
3. Alternatively, use two separate constraint sets and switch between them

For TCL-based flows:
```tcl
# For production target:
read_xdc constraints/xc7a200t_fbg484.xdc

# For upstream target:
read_xdc constraints/xc7a50t_ftg256.xdc

# For Trenz TE0712/TE0701 split target:
read_xdc constraints/te0712_te0701_minimal.xdc
```

## Top Modules by Target

| Target | Top module | Notes |
|--------|------------|-------|
| Upstream FTG256 | `radar_system_top` | Legacy board support |
| Production FBG484 | `radar_system_top` | Main AERIS-10 board |
| Trenz TE0712/TE0701 | `radar_system_top_te0712_dev` | Minimal bring-up wrapper while pinout/peripherals are migrated |

## Trenz Split Status

- `constraints/te0712_te0701_minimal.xdc` currently includes verified TE0712 pins:
  - `clk_100m` -> `R4` (TE0712 `CLK1B[0]`, 50 MHz source)
  - `reset_n` -> `T3` (TE0712 reset pin)
- `user_led` and `system_status` are now mapped to TE0701 FMC LA lines through TE0712 B16
  package pins (GPIO export path, not TE0701 onboard LED D1..D8).
- Temporary `NSTD-1`/`UCIO-1` severity downgrades were removed after pin assignment.

### Current GPIO Export Map

| Port | TE0712 package pin | TE0712 net | TE0701 FMC net |
|------|---------------------|------------|----------------|
| `user_led[0]` | `A19` | `B16_L17_N` | `FMC_LA14_N` |
| `user_led[1]` | `A18` | `B16_L17_P` | `FMC_LA14_P` |
| `user_led[2]` | `F20` | `B16_L18_N` | `FMC_LA13_N` |
| `user_led[3]` | `F19` | `B16_L18_P` | `FMC_LA13_P` |
| `system_status[0]` | `F18` | `B16_L15_P` | `FMC_LA5_N` |
| `system_status[1]` | `E18` | `B16_L15_N` | `FMC_LA5_P` |
| `system_status[2]` | `C22` | `B16_L20_P` | `FMC_LA6_N` |
| `system_status[3]` | `B22` | `B16_L20_N` | `FMC_LA6_P` |

Note: FMC direction/N/P labeling must be validated against TE0701 connector orientation
and I/O Planner before final hardware sign-off.

## Trenz Batch Build

Use the dedicated script for the split dev target:

```bash
vivado -mode batch -source scripts/build_te0712_dev.tcl
```

Outputs:
- Project directory: `vivado_te0712_dev/`
- Reports: `vivado_te0712_dev/reports/`
- Top module: `radar_system_top_te0712_dev`
- Constraint file: `constraints/te0712_te0701_minimal.xdc`

## Notes

- The production XDC pin assignments are **recommended** for the new PCB.
  The PCB designer should follow this allocation.
- Bank 16 (FT601) is fully utilized at 50/50 pins. No room for expansion
  on that bank.
- Bank 35 (status/debug) is also at capacity (50/50). Additional debug
  signals should use Bank 13 spare pins (18 remaining).
- Clock inputs are placed on MRCC (Multi-Region Clock Capable) pins to
  ensure proper clock tree access.
