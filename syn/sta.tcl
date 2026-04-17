# ------------------------------------------------------------------------
# OpenSTA script — AttoIO macro timing analysis
# ------------------------------------------------------------------------

set PDK_ROOT     "/Users/mshalan/work/pdks/volare/sky130/versions/0fe599b2afb6708d281543108caf8310912f54af/sky130A"
set LIB_STD      "$PDK_ROOT/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib"
set NETLIST      "build/attoio_macro.syn.v"
set SDC          "syn/attoio.sdc"
set TOP          "attoio_macro"

# ------------------------------------------------------------------
# 1. Read libraries (DFFRAM is now real sky130 cells; no stub needed)
# ------------------------------------------------------------------
read_liberty $LIB_STD

# ------------------------------------------------------------------
# 2. Read netlist & link
# ------------------------------------------------------------------
read_verilog $NETLIST
link_design $TOP

# SDC writes capacitance in fF; override command-line unit so
# `set_load 17.5` is interpreted as 17.5 fF.
set_cmd_units -capacitance fF

# ------------------------------------------------------------------
# 3. Read SDC
# ------------------------------------------------------------------
read_sdc $SDC

# ------------------------------------------------------------------
# 4. Clock checks
# ------------------------------------------------------------------
puts "\n========== Clock properties =========="
report_clock_properties

# ------------------------------------------------------------------
# 5. Design-rule checks
# ------------------------------------------------------------------
puts "\n========== Check SDC =========="
check_setup -verbose

# ------------------------------------------------------------------
# 6. Timing reports
# ------------------------------------------------------------------
puts "\n========== WNS / TNS per clock (setup) =========="
report_wns
report_tns

puts "\n========== Worst setup paths (sysclk) =========="
report_checks -path_delay max -group_count 5 -slack_max 100 \
              -format full_clock_expanded -digits 3

puts "\n========== Worst hold paths (sysclk) =========="
report_checks -path_delay min -group_count 5 -slack_max 100 \
              -format full_clock_expanded -digits 3

puts "\n========== Clock-to-clock summary =========="
report_checks -group_count 3 -path_group sysclk -digits 3
report_checks -group_count 3 -path_group clk_iop -digits 3

# ------------------------------------------------------------------
# 7. Design rule violations
# ------------------------------------------------------------------
puts "\n========== Max transition / capacitance / fanout =========="
report_check_types -max_slew -max_capacitance -max_fanout -violators

# ------------------------------------------------------------------
# 8. Power
# ------------------------------------------------------------------
# OpenSTA uses activity-based power. With no SAIF/VCD loaded,
# set_power_activity uses a default activity of 0.1 (10% toggle rate).
puts "\n========== Power (default 10% activity) =========="
set_power_activity -input -activity 0.1
report_power

# ------------------------------------------------------------------
# 9. Final summary
# ------------------------------------------------------------------
puts "\n========== Summary =========="
puts "Setup WNS:"
report_worst_slack -max
puts "Hold WNS:"
report_worst_slack -min

exit 0
