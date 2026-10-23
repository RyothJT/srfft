# ============================================================
# Design Compiler synthesis with SRAM black-box placeholders
# Top module: r22_fft_top
# ============================================================

set DESIGN_NAME r22_fft_top

# Resolve project directories
if {[file isdirectory "./src"]} {
    set ROOT_DIR "."
    set SYN_DIR  "./syn"
} elseif {[file isdirectory "../src"]} {
    set ROOT_DIR ".."
    set SYN_DIR  "."
} else {
    puts "ERROR: Cannot locate src/ directory."
    exit 1
}

set SRC_DIR         "${ROOT_DIR}/src"
set CONSTRAINTS_FILE "${SYN_DIR}/constraints/fft_constraints.tcl"
set SRAM_FILE       "${SRC_DIR}/memory/sram_dummy.sv"

foreach dir [list "./outputs" "./reports" "./logs"] {
    file mkdir $dir
}

puts "\n============================================================"
puts "Synthesis: $DESIGN_NAME"
puts "============================================================"

# ------------------------------------------------------------
# 1. Read RTL
# ------------------------------------------------------------

if {![file exists "${SRC_DIR}/pkg/fft_pkg.sv"]} {
    puts "ERROR: FFT package not found."
    exit 1
}

if {![file exists $SRAM_FILE]} {
    puts "ERROR: SRAM stub not found: $SRAM_FILE"
    exit 1
}

if {![file exists $CONSTRAINTS_FILE]} {
    puts "ERROR: Constraints file not found: $CONSTRAINTS_FILE"
    exit 1
}

# Analyze package first
analyze -format sverilog -library WORK \
    "${SRC_DIR}/pkg/fft_pkg.sv"

# Analyze all RTL, including sram_dummy.sv, once
analyze -autoread -recursive -verbose -rebuild \
    -format sverilog -library WORK $SRC_DIR

# ------------------------------------------------------------
# 2. Elaborate and link
# ------------------------------------------------------------

elaborate $DESIGN_NAME -library WORK
current_design $DESIGN_NAME
link

puts "\n========== ELABORATED DESIGN =========="
current_design
report_reference -hierarchy

# ------------------------------------------------------------
# 3. Check SRAM instances
# ------------------------------------------------------------

puts "\n========== PRE-SYNTHESIS SRAM CHECK =========="

set sram_designs [get_designs *sram_dummy*]
puts "Loaded SRAM-related designs: [sizeof_collection $sram_designs]"

# Use instance-name matching for a diagnostic count.
set sram_cells [get_cells -hierarchical *sram*]
puts "Cells with SRAM in their instance name: [sizeof_collection $sram_cells]"

if {[sizeof_collection $sram_cells] > 0} {
    puts "SRAM-related instances:"
    foreach_in_collection cell $sram_cells {
        puts "  [get_object_name $cell]"
    }

    # Protect matched instances from optimization.
    set_dont_touch $sram_cells true
} else {
    puts "WARNING: No instances matched *sram*."
    puts "Check report_reference and the elaborated hierarchy."
}

# ------------------------------------------------------------
# 4. Constraints
# ------------------------------------------------------------

source $CONSTRAINTS_FILE

# Protect clock network during synthesis
set_dont_touch_network [get_clocks]

# Set operating conditions if supported by the target library
set_operating_conditions -analysis_type bc_wc -max tt0p8v25c

# ------------------------------------------------------------
# 5. Path groups
# ------------------------------------------------------------

group_path -name inputs  -from [all_inputs]
group_path -name outputs -to [all_outputs]
group_path -name comb    -from [all_inputs] -to [all_outputs]

if {[sizeof_collection [all_registers -clock_pins]] > 0 &&
    [sizeof_collection [all_registers -data_pins]] > 0} {
    group_path -name reg2reg \
        -from [all_registers -clock_pins] \
        -to   [all_registers -data_pins]
}

set_critical_range 2000 [current_design]

# ------------------------------------------------------------
# 6. Synthesis
# ------------------------------------------------------------

puts "\n========== RUNNING COMPILE_ULTRA =========="

set_app_var fsm_auto_inferring true
set_app_var fsm_enable_state_minimization true

compile_ultra

puts "\n========== RUNNING INCREMENTAL COMPILE =========="

compile_ultra -incremental

# ------------------------------------------------------------
# 7. Final SRAM check
# ------------------------------------------------------------

puts "\n========== POST-SYNTHESIS SRAM CHECK =========="

set sram_cells [get_cells -hierarchical *sram*]
puts "Cells with SRAM in their instance name: [sizeof_collection $sram_cells]"

foreach_in_collection cell $sram_cells {
    puts "  [get_object_name $cell]"
}

# ------------------------------------------------------------
# 8. Write outputs
# ------------------------------------------------------------

write_file -format verilog -hierarchy \
    -output "./outputs/${DESIGN_NAME}.vg"

write_file -format ddc -hierarchy \
    -output "./outputs/${DESIGN_NAME}.ddc"

write_sdc -nosplit "./outputs/${DESIGN_NAME}.sdc"

# ------------------------------------------------------------
# 9. Reports
# ------------------------------------------------------------

report_reference -hierarchy -nosplit
report_qor
check_design

puts "\n============================================================"
puts "FINAL AREA REPORT"
puts "============================================================"

report_area

puts "\n============================================================"
puts "SYNTHESIS COMPLETE"
puts "============================================================"
