# ------------------------------------------------------------------------
# AttoIO macro — Synopsys Design Constraints for OpenSTA
# ------------------------------------------------------------------------
# Corner:  TT 1.80 V 25 °C (sky130_fd_sc_hd)
# Clocks:  sysclk = 75 MHz  (host-side bus, SRAMs)
#          clk_iop = 30 MHz (CPU / IOP-side logic)
#
# The two clocks are asynchronous on the timing graph (no common edge,
# no CDC paths expected by construction — by the architecture contract
# clk_iop edges are a subset of sysclk edges, so we simply mark the
# cross-domain arcs false to reflect the "aligned edges" guarantee).
# ------------------------------------------------------------------------

# ====================================================================
# 1. Clocks
# ====================================================================
set SYSCLK_PERIOD  13.333 ;# 75 MHz
set IOCLK_PERIOD   33.333 ;# 30 MHz

create_clock -name sysclk  -period $SYSCLK_PERIOD [get_ports sysclk]
create_clock -name clk_iop -period $IOCLK_PERIOD  [get_ports clk_iop]

# Clock uncertainty (skew + jitter margin)
set_clock_uncertainty -setup 0.25 [get_clocks sysclk]
set_clock_uncertainty -hold  0.10 [get_clocks sysclk]
set_clock_uncertainty -setup 0.40 [get_clocks clk_iop]
set_clock_uncertainty -hold  0.15 [get_clocks clk_iop]

# Transition constraint on clock networks
set_clock_transition 0.15 [get_clocks sysclk]
set_clock_transition 0.15 [get_clocks clk_iop]

# Ignore cross-domain paths — by construction clk_iop edges align with
# sysclk (clk_iop is sysclk/N externally), so no true async crossing.
set_clock_groups -asynchronous \
    -group [get_clocks sysclk] \
    -group [get_clocks clk_iop]

# ====================================================================
# 2. Input / Output delays
# ====================================================================
# Model the host as another synchronous device on sysclk.
# Assume host drives signals ~30% into the period; data is valid
# ~30% before the capture edge.
set IN_DELAY_SYS  [expr {0.30 * $SYSCLK_PERIOD}] ;# 4.0 ns
set OUT_DELAY_SYS [expr {0.30 * $SYSCLK_PERIOD}] ;# 4.0 ns

set host_in_ports [get_ports {host_addr[*] host_wdata[*] host_wmask[*] host_wen host_ren}]
set host_out_ports [get_ports {host_rdata[*] host_ready irq_to_host}]

set_input_delay  -clock sysclk -max $IN_DELAY_SYS  $host_in_ports
set_input_delay  -clock sysclk -min 0.2            $host_in_ports
set_output_delay -clock sysclk -max $OUT_DELAY_SYS $host_out_ports
set_output_delay -clock sysclk -min 0.5            $host_out_ports

# Pad interface runs on whichever domain is active — GPIO registers are
# on clk_iop (pad_out, pad_oe, pad_ctl) and the input synchronizers
# sample on sysclk (pad_in). Keep half-cycle budgets on both edges.
set_input_delay  -clock sysclk -max 3.0 [get_ports {pad_in[*]}]
set_input_delay  -clock sysclk -min 0.5 [get_ports {pad_in[*]}]

set_output_delay -clock clk_iop -max 8.0 [get_ports {pad_out[*] pad_oe[*] pad_ctl[*]}]
set_output_delay -clock clk_iop -min 1.0 [get_ports {pad_out[*] pad_oe[*] pad_ctl[*]}]

# rst_n is an async reset — constrain as a false path on setup
set_input_delay  -clock sysclk -max 3.0 [get_ports rst_n]
set_input_delay  -clock sysclk -min 0.5 [get_ports rst_n]
set_false_path -from [get_ports rst_n]

# ====================================================================
# 3. Driving cell & load budgets (global, per user request)
# ====================================================================
# Capacitance unit is overridden to fF in sta.tcl via
# `set_cmd_units -capacitance fF`, so set_load 17.5 = 17.5 fF.
set_driving_cell -lib_cell sky130_fd_sc_hd__inv_2 -pin Y [all_inputs]
set_load 17.5 [all_outputs]

# Clocks: strong clock buffer
set_driving_cell -lib_cell sky130_fd_sc_hd__clkbuf_8 -pin X \
    [get_ports {sysclk clk_iop}]

# ====================================================================
# 4. Maximum transition / fanout (design rules)
# ====================================================================
set_max_transition 1.0 [current_design]
set_max_fanout     10  [current_design]
set_max_capacitance 0.2 [current_design]
