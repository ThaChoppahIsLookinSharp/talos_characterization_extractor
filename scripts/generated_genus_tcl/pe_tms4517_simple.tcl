###############################################################################
# Auto-generated Genus TCL for pe_tms4517_simple
###############################################################################

set PE_NAME  "pe_tms4517_simple"
set TOP      "pe"
set FILELIST "/eda/home/dlamana/tfm/scripts/generated_filelists/pe_tms4517_simple.f"
set OUT_DIR  "/eda/home/dlamana/tfm/reports/pe_characterization/pe_tms4517_simple"
set LIB      "/eda/TSMC/65/CMOS/LP/stclib/9-track/tcbn65lp-set/tcbn65lp_220a_FE/TSMCHOME/digital/Front_End/timing_power_noise/NLDM/tcbn65lp_220a/tcbn65lpwc.lib"
set CLOCK_NS "5.0"

file mkdir $OUT_DIR

puts "============================================================"
puts "Genus PE synthesis"
puts "============================================================"
puts "PE_NAME  = $PE_NAME"
puts "TOP      = $TOP"
puts "FILELIST = $FILELIST"
puts "OUT_DIR  = $OUT_DIR"
puts "LIB      = $LIB"
puts "CLOCK_NS = $CLOCK_NS"
puts "============================================================"

if {![file exists $FILELIST]} {
    puts "ERROR: filelist does not exist: $FILELIST"
    exit 1
}

if {![file exists $LIB]} {
    puts "ERROR: Liberty does not exist: $LIB"
    exit 1
}

read_libs $LIB
read_hdl -sv -f $FILELIST

elaborate $TOP
current_design $TOP

check_design > $OUT_DIR/check_design.rpt

set clk_port ""

foreach candidate {clk clock i_clk clk_i clock_i i_clock} {
    set ports [get_ports $candidate]
    if {[llength $ports] > 0} {
        set clk_port $candidate
        break
    }
}

if {$clk_port eq ""} {
    puts "WARNING: No clock port found. Timing reports will be less meaningful."
} else {
    puts "INFO: Using clock port: $clk_port"

    create_clock -name clk -period $CLOCK_NS [get_ports $clk_port]

    set all_in [all_inputs]
    set clk_in [get_ports $clk_port]
    set input_ports_no_clk [remove_from_collection $all_in $clk_in]

    if {[sizeof_collection $input_ports_no_clk] > 0} {
        set_input_delay [expr {$CLOCK_NS * 0.10}] -clock clk $input_ports_no_clk
    }

    if {[sizeof_collection [all_outputs]] > 0} {
        set_output_delay [expr {$CLOCK_NS * 0.10}] -clock clk [all_outputs]
        set_load 0.01 [all_outputs]
    }

    report_clocks > $OUT_DIR/clocks.rpt
}

syn_generic
syn_map
syn_opt

report_qor    > $OUT_DIR/qor.rpt
report_timing -max_paths 20 -path_type full_clock > $OUT_DIR/timing.rpt
report_area   > $OUT_DIR/area.rpt
report_power  > $OUT_DIR/power.rpt
report_gates  > $OUT_DIR/gates.rpt

write_hdl > $OUT_DIR/${TOP}_netlist.v
write_sdc > $OUT_DIR/${TOP}.sdc
write_sdf > $OUT_DIR/${TOP}.sdf

puts "============================================================"
puts "Finished PE synthesis: $PE_NAME"
puts "Reports: $OUT_DIR"
puts "============================================================"

exit
