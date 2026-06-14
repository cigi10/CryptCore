# ============================================================================
# crypto_soc_wrapper.xdc
# Target: Arty A7-100T (xc7a100tcsg324-1)
# Vivado 2025.2
# ============================================================================

# ── Primary Clock Pin Assignment ─────────────────────────────────────────────
# Arty A7 100MHz oscillator is physically tied to pin E3
set_property -dict { PACKAGE_PIN E3 IOSTANDARD LVCMOS33 } [get_ports { clk_in1_0 }]
# Note: The 'create_clock' constraint is automatically managed by the 
# crypto_soc_clk_wiz_1_1 IP block. Do not manually define it here to avoid overrides.

# ── Reset (active-low button BTN0) ───────────────────────────────────────────
# Arty A7 reset button is at C2
set_property -dict { PACKAGE_PIN C2 IOSTANDARD LVCMOS33 } [get_ports { reset_rtl_0 }]

# ── UART ─────────────────────────────────────────────────────────────────────
# Arty A7 USB-UART bridge
set_property -dict { PACKAGE_PIN A9 IOSTANDARD LVCMOS33 } [get_ports { UART_0_rxd }]
set_property -dict { PACKAGE_PIN D10 IOSTANDARD LVCMOS33 } [get_ports { UART_0_txd }]

# ── Async Port False Paths (fixes TIMING-18) ─────────────────────────────────
set_false_path -from [get_ports { reset_rtl_0 }]
set_false_path -from [get_ports { UART_0_rxd  }]
set_false_path -to   [get_ports { UART_0_txd  }]

# ── AES-256 Key Schedule Multicycle Path ─────────────────────────────────────
set_multicycle_path -setup 16 -from [get_cells -hierarchical -filter {NAME =~ *key_reg_reg*}] -to [get_cells -hierarchical -filter {NAME =~ *round_keys_reg_reg*}]
set_multicycle_path -hold  15 -from [get_cells -hierarchical -filter {NAME =~ *key_reg_reg*}] -to [get_cells -hierarchical -filter {NAME =~ *round_keys_reg_reg*}]

# ── Configuration Bank Voltage (fixes CFGBVS-1) ──────────────────────────────
set_property CFGBVS         VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3  [current_design]

# ── Bitstream ────────────────────────────────────────────────────────────────
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
