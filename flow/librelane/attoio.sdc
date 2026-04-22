# AttoIO macro — PnR/signoff SDC (Phase H11)
#
# sysclk  = 60 MHz host bus
# clk_iop = 30 MHz IO-pad domain (asynchronous to sysclk)
#
# Assumptions:
#   - 150 ps setup + hold uncertainty on both clocks
#   - 3.5 % timing derate (OCV)
#   - 5 ns input/output external delay on the host bus (30 % of 16.667 ns)
#   - clock groups asynchronous

set ::env(CLOCK_PERIOD_SYSCLK)  16.667
set ::env(CLOCK_PERIOD_CLKIOP)  33.333

# ---------------------------------------------------------------- clocks ----
create_clock -name sysclk  -period 16.667 [get_ports sysclk]
create_clock -name clk_iop -period 33.333 [get_ports clk_iop]

set_clock_groups -asynchronous \
    -group [get_clocks sysclk]  \
    -group [get_clocks clk_iop]

# 150 ps setup + hold uncertainty (both clocks)
set_clock_uncertainty -setup 0.150 [get_clocks sysclk]
set_clock_uncertainty -hold  0.150 [get_clocks sysclk]
set_clock_uncertainty -setup 0.150 [get_clocks clk_iop]
set_clock_uncertainty -hold  0.150 [get_clocks clk_iop]

# Clock transition
set_clock_transition 0.150 [all_clocks]

# ---------------------------------------------------------------- derate ----
# 3.5 % OCV derate (applies to all corners; LibreLane runs each corner separately)
set_timing_derate -early 0.965
set_timing_derate -late  1.035

# ---------------------------------------------------------- input/output ----
# Host bus (APB) — 5 ns = 30 % of the 16.667 ns sysclk period
set host_inputs  [list \
    rst_n PADDR PSEL PENABLE PWRITE PWDATA PSTRB]
set host_outputs [list PRDATA PREADY PSLVERR irq_to_host]

foreach p $host_inputs {
    set_input_delay  -clock sysclk -max 5.0 [get_ports $p]
    set_input_delay  -clock sysclk -min 1.0 [get_ports $p]
}

foreach p $host_outputs {
    set_output_delay -clock sysclk -max 5.0 [get_ports $p]
    set_output_delay -clock sysclk -min 1.0 [get_ports $p]
}

# Pad domain (clk_iop) — use 25 % of 33.333 ns period
set pad_inputs  [list pad_in]
set pad_outputs [list pad_out pad_oe pad_ctl]

foreach p $pad_inputs {
    set_input_delay  -clock clk_iop -max 8.0 [get_ports $p]
    set_input_delay  -clock clk_iop -min 2.0 [get_ports $p]
}

foreach p $pad_outputs {
    set_output_delay -clock clk_iop -max 8.0 [get_ports $p]
    set_output_delay -clock clk_iop -min 2.0 [get_ports $p]
}

# ----------------------------------------------------- drives and loads -----
# Driving cell for all inputs: inv_2
set_driving_cell -lib_cell sky130_fd_sc_hd__inv_2 -pin Y [all_inputs]
# Output load: 17.5 fF (default sky130 pad estimate)
set_load 0.0175 [all_outputs]
