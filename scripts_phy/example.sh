#!/bin/bash
set -euo pipefail

###############################################################################
# Small MAC RTL -> Xcelium simulation -> Genus synthesis/timing flow
#
# Cadence / EUROPRACTICE 2025-26 flow:
#   - Xcelium: RTL simulation
#   - DDIEXPORT: exposes Genus / Innovus / Joules wrappers
#   - Genus: synthesis + timing/area/power reports
#
# Usage:
#   chmod +x run_mac_flow.sh
#   ./run_mac_flow.sh
#
# Optional overrides:
#   LIB=/eda/TSMC/65/path/to/slow.lib CLOCK_NS=5.0 ./run_mac_flow.sh
#
###############################################################################

###############################################################################
# User configuration
###############################################################################

CADENCE_SCRIPTS="${CADENCE_SCRIPTS:-/eda/cadence/2025-26/scripts}"

XCELIUM_SETUP="${XCELIUM_SETUP:-$CADENCE_SCRIPTS/XCELIUM_25.03.006_RHELx86.csh}"
DDI_SETUP="${DDI_SETUP:-$CADENCE_SCRIPTS/DDIEXPORT_23.35.000_RHELx86.csh}"

TECH_DIR="${TECH_DIR:-/eda/TSMC/65}"

DESIGN="${DESIGN:-mac}"
CLOCK_NS="${CLOCK_NS:-5.0}"

# Optional: force a specific timing library.
# Example:
#   export LIB=/eda/TSMC/65/.../slow.lib
LIB="${LIB:-}"

# Optional: standard-cell Verilog simulation model for gate-level sim.
# Leave empty unless you know the path.
# Example:
#   export VERILOG_MODEL=/eda/TSMC/65/.../stdcells.v
VERILOG_MODEL="${VERILOG_MODEL:-}"

###############################################################################
# Directory setup
###############################################################################

mkdir -p rtl tb scripts reports logs work

###############################################################################
# RTL: small sequential MAC
###############################################################################

cat > rtl/mac.sv <<'EOF'
module mac #(
    parameter int A_W   = 8,
    parameter int B_W   = 8,
    parameter int ACC_W = 32
)(
    input  logic                    clk,
    input  logic                    rst_n,
    input  logic                    en,
    input  logic                    clear,
    input  logic signed [A_W-1:0]   a,
    input  logic signed [B_W-1:0]   b,
    output logic signed [ACC_W-1:0] acc
);

    logic signed [A_W+B_W-1:0] mult;

    assign mult = a * b;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            acc <= '0;
        end else if (clear) begin
            acc <= '0;
        end else if (en) begin
            acc <= acc + mult;
        end
    end

endmodule
EOF

###############################################################################
# Testbench
###############################################################################

cat > tb/mac_tb.sv <<'EOF'
module mac_tb;

    localparam int A_W   = 8;
    localparam int B_W   = 8;
    localparam int ACC_W = 32;

    logic clk;
    logic rst_n;
    logic en;
    logic clear;

    logic signed [A_W-1:0]   a;
    logic signed [B_W-1:0]   b;
    logic signed [ACC_W-1:0] acc;

    int signed expected;

    mac #(
        .A_W(A_W),
        .B_W(B_W),
        .ACC_W(ACC_W)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .en(en),
        .clear(clear),
        .a(a),
        .b(b),
        .acc(acc)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    task automatic apply_mac(input int signed aa, input int signed bb);
        begin
            @(negedge clk);
            a  = aa[A_W-1:0];
            b  = bb[B_W-1:0];
            en = 1'b1;

            expected = expected + aa * bb;

            @(posedge clk);
            #1;

            if (acc !== expected) begin
                $display("ERROR: a=%0d b=%0d acc=%0d expected=%0d",
                         aa, bb, acc, expected);
                $fatal;
            end else begin
                $display("OK: a=%0d b=%0d acc=%0d", aa, bb, acc);
            end
        end
    endtask

    initial begin
        rst_n    = 1'b0;
        en       = 1'b0;
        clear    = 1'b0;
        a        = '0;
        b        = '0;
        expected = 0;

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        apply_mac(3, 4);
        apply_mac(-2, 5);
        apply_mac(7, -3);
        apply_mac(-4, -6);

        @(negedge clk);
        clear    = 1'b1;
        en       = 1'b0;
        a        = '0;
        b        = '0;
        expected = 0;

        @(posedge clk);
        #1;

        if (acc !== 0) begin
            $display("ERROR after clear: acc=%0d expected=0", acc);
            $fatal;
        end else begin
            $display("OK: clear acc=0");
        end

        @(negedge clk);
        clear = 1'b0;

        apply_mac(10, 10);

        $display("MAC simulation PASSED");
        $finish;
    end

endmodule
EOF

###############################################################################
# Xcelium filelist
###############################################################################

cat > scripts/filelist_rtl.f <<'EOF'
rtl/mac.sv
tb/mac_tb.sv
EOF

###############################################################################
# RTL simulation with Xcelium
###############################################################################

echo "============================================================"
echo "[1/4] Running RTL simulation with Xcelium"
echo "============================================================"

tcsh -f -c "
source $XCELIUM_SETUP
echo '[INFO] xrun path:'
which xrun
xrun -64bit \
     -sv \
     -f scripts/filelist_rtl.f \
     -top mac_tb \
     -timescale 1ns/1ps \
     -access +rwc \
     -xmlibdirname work/xcelium_rtl \
     -l logs/xrun_rtl.log
"

echo "[OK] RTL simulation finished"
echo "     Log: logs/xrun_rtl.log"

###############################################################################
# Locate technology timing library
###############################################################################

echo "============================================================"
echo "[2/4] Selecting TSMC65 .lib"
echo "============================================================"

if [[ -z "$LIB" ]]; then
    echo "[INFO] LIB not provided. Searching under: $TECH_DIR"

    LIB="$(
        find "$TECH_DIR" -type f \( -name "*.lib" -o -name "*.lib.gz" \) 2>/dev/null \
        | grep -Ei 'ss|slow|worst|wc|max' \
        | head -n 1 || true
    )"

    if [[ -z "$LIB" ]]; then
        LIB="$(
            find "$TECH_DIR" -type f \( -name "*.lib" -o -name "*.lib.gz" \) 2>/dev/null \
            | head -n 1 || true
        )"
    fi
fi

if [[ -z "$LIB" ]]; then
    echo "[ERROR] No .lib or .lib.gz found under $TECH_DIR"
    echo "        Set LIB manually, for example:"
    echo "        LIB=/eda/TSMC/65/path/to/slow.lib ./run_mac_flow.sh"
    exit 1
fi

echo "[INFO] Using timing library:"
echo "       $LIB"

export DESIGN
export LIB
export CLOCK_NS

###############################################################################
# Genus TCL script
###############################################################################

cat > scripts/genus_mac.tcl <<'EOF'
set DESIGN   $::env(DESIGN)
set LIB      $::env(LIB)
set CLOCK_NS $::env(CLOCK_NS)

set OUT_DIR reports

file mkdir $OUT_DIR

puts "============================================================"
puts "Genus synthesis setup"
puts "============================================================"
puts "Design       : $DESIGN"
puts "Library      : $LIB"
puts "Clock period : $CLOCK_NS ns"
puts "Output dir   : $OUT_DIR"
puts "============================================================"

# ---------------------------------------------------------------------------
# Library setup
# ---------------------------------------------------------------------------

set_db init_lib_search_path [list [file dirname $LIB]]
set_db library [list $LIB]

# ---------------------------------------------------------------------------
# Read and elaborate RTL
# ---------------------------------------------------------------------------

read_hdl -sv rtl/mac.sv
elaborate $DESIGN
current_design $DESIGN

check_design > $OUT_DIR/check_design.rpt

# ---------------------------------------------------------------------------
# Timing constraints
# ---------------------------------------------------------------------------

create_clock -name clk -period $CLOCK_NS [get_ports clk]

set INPUT_DELAY  [expr {$CLOCK_NS * 0.10}]
set OUTPUT_DELAY [expr {$CLOCK_NS * 0.10}]

set input_ports_no_clk [remove_from_collection [all_inputs] [get_ports clk]]

set_input_delay  $INPUT_DELAY  -clock clk $input_ports_no_clk
set_output_delay $OUTPUT_DELAY -clock clk [all_outputs]

# Small output load. Adjust later according to the real environment.
set_load 0.01 [all_outputs]

# Avoid optimizing away useful visibility.
set_db preserve true [get_ports *]

# ---------------------------------------------------------------------------
# Pre-synthesis reports
# ---------------------------------------------------------------------------

report_clocks > $OUT_DIR/clocks.rpt

# ---------------------------------------------------------------------------
# Synthesis
# ---------------------------------------------------------------------------

syn_generic
syn_map
syn_opt

# ---------------------------------------------------------------------------
# Reports
# ---------------------------------------------------------------------------

report_qor > $OUT_DIR/qor.rpt

report_timing \
    -max_paths 20 \
    -path_type full_clock \
    > $OUT_DIR/timing.rpt

report_area > $OUT_DIR/area.rpt

report_power > $OUT_DIR/power.rpt

report_gates > $OUT_DIR/gates.rpt

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

write_hdl > $OUT_DIR/${DESIGN}_netlist.v
write_sdc > $OUT_DIR/${DESIGN}.sdc
write_sdf > $OUT_DIR/${DESIGN}.sdf

puts "============================================================"
puts "Genus finished successfully"
puts "============================================================"
puts "Reports:"
puts "  $OUT_DIR/timing.rpt"
puts "  $OUT_DIR/area.rpt"
puts "  $OUT_DIR/power.rpt"
puts "  $OUT_DIR/qor.rpt"
puts "  $OUT_DIR/gates.rpt"
puts ""
puts "Generated files:"
puts "  $OUT_DIR/${DESIGN}_netlist.v"
puts "  $OUT_DIR/${DESIGN}.sdc"
puts "  $OUT_DIR/${DESIGN}.sdf"
puts "============================================================"

exit
EOF

###############################################################################
# Run Genus via DDIEXPORT
###############################################################################

echo "============================================================"
echo "[3/4] Running Genus synthesis through DDIEXPORT"
echo "============================================================"

tcsh -f -c "
source $DDI_SETUP
echo '[INFO] DDI setup loaded'
echo '[INFO] genus path:'
which genus
echo '[INFO] genus version:'
genus -version
genus -batch -files scripts/genus_mac.tcl -log logs/genus.log
"

echo "[OK] Genus synthesis finished"
echo "     Log: logs/genus.log"

###############################################################################
# Optional post-synthesis gate-level simulation
###############################################################################

echo "============================================================"
echo "[4/4] Optional gate-level simulation"
echo "============================================================"

if [[ -n "$VERILOG_MODEL" && -f "$VERILOG_MODEL" ]]; then
    echo "[INFO] Running gate-level simulation with standard-cell model:"
    echo "       $VERILOG_MODEL"

    cat > scripts/filelist_gate.f <<EOF
$VERILOG_MODEL
reports/${DESIGN}_netlist.v
tb/mac_tb.sv
EOF

    tcsh -f -c "
    source $XCELIUM_SETUP
    xrun -64bit \
         -sv \
         -f scripts/filelist_gate.f \
         -top mac_tb \
         -timescale 1ns/1ps \
         -xmlibdirname work/xcelium_gate \
         -l logs/xrun_gate.log
    "

    echo "[OK] Gate-level simulation finished"
    echo "     Log: logs/xrun_gate.log"
else
    echo "[INFO] Skipping gate-level simulation."
    echo "       Reason: VERILOG_MODEL is not set or does not exist."
    echo "       This is normal unless you have the TSMC65 standard-cell Verilog model."
fi

###############################################################################
# Final summary
###############################################################################

echo "============================================================"
echo "FLOW COMPLETED"
echo "============================================================"
echo "Main outputs:"
echo "  RTL simulation log : logs/xrun_rtl.log"
echo "  Genus log          : logs/genus.log"
echo "  Timing report      : reports/timing.rpt"
echo "  Area report        : reports/area.rpt"
echo "  Power report       : reports/power.rpt"
echo "  QoR report         : reports/qor.rpt"
echo "  Netlist            : reports/${DESIGN}_netlist.v"
echo "  SDC                : reports/${DESIGN}.sdc"
echo "  SDF                : reports/${DESIGN}.sdf"
echo ""
echo "Library used:"
echo "  $LIB"
echo ""
echo "Clock period:"
echo "  $CLOCK_NS ns"
echo "============================================================"
