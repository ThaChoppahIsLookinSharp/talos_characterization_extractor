###############################################################################
# Genus synthesis TCL for simple_mac
# WORKSPACE is expected to come from the CSGH environment.
###############################################################################

###############################################################################
# Required external environment
###############################################################################

if {![info exists env(WORKSPACE)]} {
    puts "ERROR: WORKSPACE environment variable is not set."
    puts "It should come from the CSGH environment."
    exit 1
}

###############################################################################
# User configuration
###############################################################################

set WORKSPACE $env(WORKSPACE)

set TOP "simple_mac"

set RTL "$WORKSPACE/rtl/simple_mac.sv"

set CLOCK_NS 5.0

set LIB "/eda/TSMC/65/CMOS/LP/stclib/9-track/tcbn65lp-set/tcbn65lp_220a_FE/TSMCHOME/digital/Front_End/timing_power_noise/NLDM/tcbn65lp_220a/tcbn65lpwc.lib"

set OUT_DIR "$WORKSPACE/reports/genus_${TOP}"

###############################################################################
# Setup
###############################################################################

file mkdir $OUT_DIR

puts "============================================================"
puts "Genus synthesis setup"
puts "============================================================"
puts "WORKSPACE = $WORKSPACE"
puts "TOP       = $TOP"
puts "RTL       = $RTL"
puts "LIB       = $LIB"
puts "CLOCK_NS  = $CLOCK_NS"
puts "OUT_DIR   = $OUT_DIR"
puts "============================================================"

if {![file exists $RTL]} {
    puts "ERROR: RTL file does not exist:"
    puts "  $RTL"
    exit 1
}

if {![file exists $LIB]} {
    puts "ERROR: Liberty file does not exist:"
    puts "  $LIB"
    exit 1
}

###############################################################################
# Library and RTL
###############################################################################

read_libs $LIB

read_hdl -sv $RTL

# Important: elaborate takes the module name, not the file path.
elaborate $TOP
current_design $TOP

check_design > $OUT_DIR/check_design.rpt

###############################################################################
# Constraints
###############################################################################

create_clock -name clk -period $CLOCK_NS [get_ports clk]

set input_ports_no_clk [remove_from_collection [all_inputs] [get_ports clk]]

set_input_delay  [expr {$CLOCK_NS * 0.10}] -clock clk $input_ports_no_clk
set_output_delay [expr {$CLOCK_NS * 0.10}] -clock clk [all_outputs]

set_load 0.01 [all_outputs]

report_clocks > $OUT_DIR/clocks.rpt

###############################################################################
# Synthesis
###############################################################################

syn_generic
syn_map
syn_opt

###############################################################################
# Reports
###############################################################################

report_qor > $OUT_DIR/qor.rpt

report_timing \
    -max_paths 20 \
    -path_type full_clock \
    > $OUT_DIR/timing.rpt

report_area  > $OUT_DIR/area.rpt
report_power > $OUT_DIR/power.rpt
report_gates > $OUT_DIR/gates.rpt

###############################################################################
# Outputs
###############################################################################

write_hdl > $OUT_DIR/${TOP}_netlist.v
write_sdc > $OUT_DIR/${TOP}.sdc
write_sdf > $OUT_DIR/${TOP}.sdf

puts "============================================================"
puts "Synthesis finished"
puts "Reports generated in:"
puts "  $OUT_DIR"
puts "============================================================"

exit
