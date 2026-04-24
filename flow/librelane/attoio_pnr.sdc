# AttoIO macro — PnR-time SDC (v1.3).
#
# Overconstrained clocks used during LibreLane synthesis + PnR so that
# the signoff-time SDC (attoio_signoff.sdc) lands with built-in margin.
#
#   sysclk  = 55 MHz  (18.182 ns)   vs signoff 50 MHz (20 ns)
#   clk_iop = 28 MHz  (35.714 ns)   vs signoff 25 MHz (40 ns)
#
# Margin: 1.82 ns on sysclk, 4.29 ns on clk_iop (at this SDC relative
# to the signoff SDC).  Any timing-driven optimization pass that closes
# here will have headroom when the signoff STA reopens the books.

set ::env(CLOCK_PERIOD_SYSCLK)  18.182
set ::env(CLOCK_PERIOD_CLKIOP)  35.714

# ---------------------------------------------------------------- clocks ----
create_clock -name sysclk  -period 18.182 [get_ports sysclk]
create_clock -name clk_iop -period 35.714 [get_ports clk_iop]

set_clock_groups -asynchronous \
    -group [get_clocks sysclk]  \
    -group [get_clocks clk_iop]

# 150 ps setup + hold uncertainty (both clocks)
set_clock_uncertainty -setup 0.150 [get_clocks sysclk]
set_clock_uncertainty -hold  0.150 [get_clocks sysclk]
set_clock_uncertainty -setup 0.150 [get_clocks clk_iop]
set_clock_uncertainty -hold  0.150 [get_clocks clk_iop]

set_clock_transition 0.150 [all_clocks]

# ---------------------------------------------------------------- derate ----
set_timing_derate -early 0.965
set_timing_derate -late  1.035

# ---------------------------------------------------------- input/output ----
# Min input delay uniformly 2 ns on all inputs (both host and pad domains).
# Max input delay scaled to 25 % of each clock's period.

set host_inputs  [list \
    rst_n PADDR PSEL PENABLE PWRITE PWDATA PSTRB]
set host_outputs [list PRDATA PREADY PSLVERR irq_to_host]

foreach p $host_inputs {
    set_input_delay  -clock sysclk -max 4.5 [get_ports $p]
    set_input_delay  -clock sysclk -min 2.0 [get_ports $p]
}

foreach p $host_outputs {
    set_output_delay -clock sysclk -max 4.5 [get_ports $p]
    set_output_delay -clock sysclk -min 2.0 [get_ports $p]
}

set pad_inputs  [list pad_in]
set pad_outputs [list pad_out pad_oe pad_ctl]

foreach p $pad_inputs {
    set_input_delay  -clock clk_iop -max 9.0 [get_ports $p]
    set_input_delay  -clock clk_iop -min 2.0 [get_ports $p]
}

foreach p $pad_outputs {
    set_output_delay -clock clk_iop -max 9.0 [get_ports $p]
    set_output_delay -clock clk_iop -min 2.0 [get_ports $p]
}

# ----------------------------------------------------- drives and loads -----
set_driving_cell -lib_cell sky130_fd_sc_hd__inv_2 -pin Y [all_inputs]
set_load 0.0175 [all_outputs]
