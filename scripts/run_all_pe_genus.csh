#!/bin/tcsh -f

###############################################################################
# Synthesize PE variants with Cadence Genus.
#
# Expected workspace structure:
#
#   $WORKSPACE/rtl/pe/2D-Systolic-Array-Multiplier/pe.sv
#   $WORKSPACE/rtl/pe/gemmini/gemmini_pe.sv
#   $WORKSPACE/rtl/pe/sauria/...
#
# Outputs:
#
#   $WORKSPACE/reports/pe_characterization/<pe_name>/
#
# Usage:
#
#   cd $WORKSPACE
#   chmod +x scripts/run_all_pe_genus.csh
#   scripts/run_all_pe_genus.csh
#
###############################################################################

###############################################################################
# Basic environment checks
###############################################################################

if (! $?WORKSPACE) then
    echo "[ERROR] WORKSPACE is not set."
    echo "        It should come from the CSGH environment."
    exit 1
endif

echo "============================================================"
echo "PE Genus synthesis flow"
echo "============================================================"
echo "WORKSPACE = $WORKSPACE"
echo "============================================================"

###############################################################################
# Cadence / license setup
###############################################################################

set CADENCE_SCRIPTS = "/eda/cadence/2025-26/scripts"
set DDI_SETUP       = "$CADENCE_SCRIPTS/DDIEXPORT_23.35.000_RHELx86.csh"

if (! -f "$DDI_SETUP") then
    echo "[ERROR] DDI setup script not found:"
    echo "        $DDI_SETUP"
    exit 1
endif

source "$DDI_SETUP"

setenv CDS_LIC_FILE "5280@158.109.74.93"
setenv LM_LICENSE_FILE "$CDS_LIC_FILE"

echo "[INFO] Genus binary:"
which genus

###############################################################################
# Technology library and synthesis setup
###############################################################################

set LIB = "/eda/TSMC/65/CMOS/LP/stclib/9-track/tcbn65lp-set/tcbn65lp_220a_FE/TSMCHOME/digital/Front_End/timing_power_noise/NLDM/tcbn65lp_220a/tcbn65lpwc.lib"

if (! -f "$LIB") then
    echo "[ERROR] Liberty file not found:"
    echo "        $LIB"
    exit 1
endif

set CLOCK_NS = "5.0"

set RUN_ROOT     = "$WORKSPACE/reports/pe_characterization"
set FILELIST_DIR = "$WORKSPACE/scripts/generated_filelists"
set TCL_DIR      = "$WORKSPACE/scripts/generated_genus_tcl"

mkdir -p "$RUN_ROOT"
mkdir -p "$FILELIST_DIR"
mkdir -p "$TCL_DIR"

###############################################################################
# Helper: generate and run one PE
###############################################################################

# ---------------------------------------------------------------------------
# PE 1: tms4517 2D systolic PE
# ---------------------------------------------------------------------------

set PE_NAME  = "pe_tms4517_simple"
set TOP      = "pe"
set FILELIST = "$FILELIST_DIR/${PE_NAME}.f"
set OUT_DIR  = "$RUN_ROOT/${PE_NAME}"
set TCL      = "$TCL_DIR/${PE_NAME}.tcl"
set LOG      = "$RUN_ROOT/${PE_NAME}.log"

if (! -f "$WORKSPACE/rtl/pe/2D-Systolic-Array-Multiplier/pe.sv") then
    echo "[ERROR] Missing RTL:"
    echo "        $WORKSPACE/rtl/pe/2D-Systolic-Array-Multiplier/pe.sv"
    exit 1
endif

echo "$WORKSPACE/rtl/pe/2D-Systolic-Array-Multiplier/pe.sv" > "$FILELIST"

cat > "$TCL" << EOF
###############################################################################
# Auto-generated Genus TCL for $PE_NAME
###############################################################################

set PE_NAME  "$PE_NAME"
set TOP      "$TOP"
set FILELIST "$FILELIST"
set OUT_DIR  "$OUT_DIR"
set LIB      "$LIB"
set CLOCK_NS "$CLOCK_NS"

file mkdir \$OUT_DIR

puts "============================================================"
puts "Genus PE synthesis"
puts "============================================================"
puts "PE_NAME  = \$PE_NAME"
puts "TOP      = \$TOP"
puts "FILELIST = \$FILELIST"
puts "OUT_DIR  = \$OUT_DIR"
puts "LIB      = \$LIB"
puts "CLOCK_NS = \$CLOCK_NS"
puts "============================================================"

if {![file exists \$FILELIST]} {
    puts "ERROR: filelist does not exist: \$FILELIST"
    exit 1
}

if {![file exists \$LIB]} {
    puts "ERROR: Liberty does not exist: \$LIB"
    exit 1
}

read_libs \$LIB
read_hdl -sv -f \$FILELIST

elaborate \$TOP
current_design \$TOP

check_design > \$OUT_DIR/check_design.rpt

set clk_port ""

foreach candidate {clk clock i_clk clk_i clock_i i_clock} {
    set ports [get_ports \$candidate]
    if {[llength \$ports] > 0} {
        set clk_port \$candidate
        break
    }
}

if {\$clk_port eq ""} {
    puts "WARNING: No clock port found. Timing reports will be less meaningful."
} else {
    puts "INFO: Using clock port: \$clk_port"

    create_clock -name clk -period \$CLOCK_NS [get_ports \$clk_port]

    set all_in [all_inputs]
    set clk_in [get_ports \$clk_port]
    set input_ports_no_clk [remove_from_collection \$all_in \$clk_in]

    if {[sizeof_collection \$input_ports_no_clk] > 0} {
        set_input_delay [expr {\$CLOCK_NS * 0.10}] -clock clk \$input_ports_no_clk
    }

    if {[sizeof_collection [all_outputs]] > 0} {
        set_output_delay [expr {\$CLOCK_NS * 0.10}] -clock clk [all_outputs]
        set_load 0.01 [all_outputs]
    }

    report_clocks > \$OUT_DIR/clocks.rpt
}

syn_generic
syn_map
syn_opt

report_qor    > \$OUT_DIR/qor.rpt
report_timing -max_paths 20 -path_type full_clock > \$OUT_DIR/timing.rpt
report_area   > \$OUT_DIR/area.rpt
report_power  > \$OUT_DIR/power.rpt
report_gates  > \$OUT_DIR/gates.rpt

write_hdl > \$OUT_DIR/\${TOP}_netlist.v
write_sdc > \$OUT_DIR/\${TOP}.sdc
write_sdf > \$OUT_DIR/\${TOP}.sdf

puts "============================================================"
puts "Finished PE synthesis: \$PE_NAME"
puts "Reports: \$OUT_DIR"
puts "============================================================"

exit
EOF

echo "============================================================"
echo "[RUN] $PE_NAME"
echo "============================================================"
genus -batch -files "$TCL" -log "$LOG"

# ---------------------------------------------------------------------------
# PE 2: Gemmini-like PE translated to SystemVerilog
# ---------------------------------------------------------------------------

set PE_NAME  = "pe_gemmini_like"
set TOP      = "pe_gemmini_like"
set FILELIST = "$FILELIST_DIR/${PE_NAME}.f"
set OUT_DIR  = "$RUN_ROOT/${PE_NAME}"
set TCL      = "$TCL_DIR/${PE_NAME}.tcl"
set LOG      = "$RUN_ROOT/${PE_NAME}.log"

if (! -f "$WORKSPACE/rtl/pe/gemmini/gemmini_pe.sv") then
    echo "[ERROR] Missing RTL:"
    echo "        $WORKSPACE/rtl/pe/gemmini/gemmini_pe.sv"
    exit 1
endif

echo "$WORKSPACE/rtl/pe/gemmini/gemmini_pe.sv" > "$FILELIST"

cat > "$TCL" << EOF
###############################################################################
# Auto-generated Genus TCL for $PE_NAME
###############################################################################

set PE_NAME  "$PE_NAME"
set TOP      "$TOP"
set FILELIST "$FILELIST"
set OUT_DIR  "$OUT_DIR"
set LIB      "$LIB"
set CLOCK_NS "$CLOCK_NS"

file mkdir \$OUT_DIR

puts "============================================================"
puts "Genus PE synthesis"
puts "============================================================"
puts "PE_NAME  = \$PE_NAME"
puts "TOP      = \$TOP"
puts "FILELIST = \$FILELIST"
puts "OUT_DIR  = \$OUT_DIR"
puts "LIB      = \$LIB"
puts "CLOCK_NS = \$CLOCK_NS"
puts "============================================================"

if {![file exists \$FILELIST]} {
    puts "ERROR: filelist does not exist: \$FILELIST"
    exit 1
}

if {![file exists \$LIB]} {
    puts "ERROR: Liberty does not exist: \$LIB"
    exit 1
}

read_libs \$LIB
read_hdl -sv -f \$FILELIST

elaborate \$TOP
current_design \$TOP

check_design > \$OUT_DIR/check_design.rpt

set clk_port ""

foreach candidate {clk clock i_clk clk_i clock_i i_clock} {
    set ports [get_ports \$candidate]
    if {[llength \$ports] > 0} {
        set clk_port \$candidate
        break
    }
}

if {\$clk_port eq ""} {
    puts "WARNING: No clock port found. Timing reports will be less meaningful."
} else {
    puts "INFO: Using clock port: \$clk_port"

    create_clock -name clk -period \$CLOCK_NS [get_ports \$clk_port]

    set all_in [all_inputs]
    set clk_in [get_ports \$clk_port]
    set input_ports_no_clk [remove_from_collection \$all_in \$clk_in]

    if {[sizeof_collection \$input_ports_no_clk] > 0} {
        set_input_delay [expr {\$CLOCK_NS * 0.10}] -clock clk \$input_ports_no_clk
    }

    if {[sizeof_collection [all_outputs]] > 0} {
        set_output_delay [expr {\$CLOCK_NS * 0.10}] -clock clk [all_outputs]
        set_load 0.01 [all_outputs]
    }

    report_clocks > \$OUT_DIR/clocks.rpt
}

syn_generic
syn_map
syn_opt

report_qor    > \$OUT_DIR/qor.rpt
report_timing -max_paths 20 -path_type full_clock > \$OUT_DIR/timing.rpt
report_area   > \$OUT_DIR/area.rpt
report_power  > \$OUT_DIR/power.rpt
report_gates  > \$OUT_DIR/gates.rpt

write_hdl > \$OUT_DIR/\${TOP}_netlist.v
write_sdc > \$OUT_DIR/\${TOP}.sdc
write_sdf > \$OUT_DIR/\${TOP}.sdf

puts "============================================================"
puts "Finished PE synthesis: \$PE_NAME"
puts "Reports: \$OUT_DIR"
puts "============================================================"

exit
EOF

echo "============================================================"
echo "[RUN] $PE_NAME"
echo "============================================================"
genus -batch -files "$TCL" -log "$LOG"

# ---------------------------------------------------------------------------
# PE 3: SAURIA processing element
# ---------------------------------------------------------------------------

set PE_NAME  = "pe_sauria"
set TOP      = "sa_processing_element"
set FILELIST = "$FILELIST_DIR/${PE_NAME}.f"
set OUT_DIR  = "$RUN_ROOT/${PE_NAME}"
set TCL      = "$TCL_DIR/${PE_NAME}.tcl"
set LOG      = "$RUN_ROOT/${PE_NAME}.log"

if (! -f "$WORKSPACE/rtl/pe/sauria/sa_processing_element.sv") then
    echo "[ERROR] Missing RTL:"
    echo "        $WORKSPACE/rtl/pe/sauria/sa_processing_element.sv"
    exit 1
endif

find "$WORKSPACE/rtl/pe/sauria" -type f -name "*.sv" | sort > "$FILELIST"

cat > "$TCL" << EOF
###############################################################################
# Auto-generated Genus TCL for $PE_NAME
###############################################################################

set PE_NAME  "$PE_NAME"
set TOP      "$TOP"
set FILELIST "$FILELIST"
set OUT_DIR  "$OUT_DIR"
set LIB      "$LIB"
set CLOCK_NS "$CLOCK_NS"

file mkdir \$OUT_DIR

puts "============================================================"
puts "Genus PE synthesis"
puts "============================================================"
puts "PE_NAME  = \$PE_NAME"
puts "TOP      = \$TOP"
puts "FILELIST = \$FILELIST"
puts "OUT_DIR  = \$OUT_DIR"
puts "LIB      = \$LIB"
puts "CLOCK_NS = \$CLOCK_NS"
puts "============================================================"

if {![file exists \$FILELIST]} {
    puts "ERROR: filelist does not exist: \$FILELIST"
    exit 1
}

if {![file exists \$LIB]} {
    puts "ERROR: Liberty does not exist: \$LIB"
    exit 1
}

read_libs \$LIB
read_hdl -sv -f \$FILELIST

elaborate \$TOP
current_design \$TOP

check_design > \$OUT_DIR/check_design.rpt

set clk_port ""

foreach candidate {clk clock i_clk clk_i clock_i i_clock} {
    set ports [get_ports \$candidate]
    if {[llength \$ports] > 0} {
        set clk_port \$candidate
        break
    }
}

if {\$clk_port eq ""} {
    puts "WARNING: No clock port found. Timing reports will be less meaningful."
} else {
    puts "INFO: Using clock port: \$clk_port"

    create_clock -name clk -period \$CLOCK_NS [get_ports \$clk_port]

    set all_in [all_inputs]
    set clk_in [get_ports \$clk_port]
    set input_ports_no_clk [remove_from_collection \$all_in \$clk_in]

    if {[sizeof_collection \$input_ports_no_clk] > 0} {
        set_input_delay [expr {\$CLOCK_NS * 0.10}] -clock clk \$input_ports_no_clk
    }

    if {[sizeof_collection [all_outputs]] > 0} {
        set_output_delay [expr {\$CLOCK_NS * 0.10}] -clock clk [all_outputs]
        set_load 0.01 [all_outputs]
    }

    report_clocks > \$OUT_DIR/clocks.rpt
}

syn_generic
syn_map
syn_opt

report_qor    > \$OUT_DIR/qor.rpt
report_timing -max_paths 20 -path_type full_clock > \$OUT_DIR/timing.rpt
report_area   > \$OUT_DIR/area.rpt
report_power  > \$OUT_DIR/power.rpt
report_gates  > \$OUT_DIR/gates.rpt

write_hdl > \$OUT_DIR/\${TOP}_netlist.v
write_sdc > \$OUT_DIR/\${TOP}.sdc
write_sdf > \$OUT_DIR/\${TOP}.sdf

puts "============================================================"
puts "Finished PE synthesis: \$PE_NAME"
puts "Reports: \$OUT_DIR"
puts "============================================================"

exit
EOF

echo "============================================================"
echo "[RUN] $PE_NAME"
echo "============================================================"
genus -batch -files "$TCL" -log "$LOG"

###############################################################################
# Optional parsing
###############################################################################

echo "============================================================"
echo "Parsing generated reports"
echo "============================================================"

if (-f "$WORKSPACE/scripts/parse_genus_reports.py") then
    foreach pe ("pe_tms4517_simple" "pe_gemmini_like" "pe_sauria")
        echo "------------------------------------------------------------"
        echo "[PARSE] $pe"
        echo "------------------------------------------------------------"

        python3 "$WORKSPACE/scripts/parse_genus_reports.py" "$RUN_ROOT/$pe" --lib "$LIB"
        python3 "$WORKSPACE/scripts/parse_genus_reports.py" "$RUN_ROOT/$pe" --lib "$LIB" --json > "$RUN_ROOT/$pe/ppa_summary.json"
    end
else
    echo "[WARN] Parser not found:"
    echo "       $WORKSPACE/scripts/parse_genus_reports.py"
endif

###############################################################################
# Final summary
###############################################################################

echo "============================================================"
echo "ALL PE SYNTHESIS RUNS FINISHED"
echo "============================================================"
echo "Reports root:"
echo "  $RUN_ROOT"
echo ""
echo "Generated PE report dirs:"
echo "  $RUN_ROOT/pe_tms4517_simple"
echo "  $RUN_ROOT/pe_gemmini_like"
echo "  $RUN_ROOT/pe_sauria"
echo ""
echo "Generated Genus TCLs:"
echo "  $TCL_DIR"
echo ""
echo "Generated filelists:"
echo "  $FILELIST_DIR"
echo "============================================================"

