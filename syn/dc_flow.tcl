###################################################################
# Synopsys Design Compiler Synthesis Script
# Project: Linear Radix-2^2 SDF Pipelined FFT Processor
# Top Module: r22_fft_top
###################################################################

set DESIGN_NAME r22_fft_top

puts "Hostname : [info hostname]"

################################
# Directory Housekeeping & Path Resolution
################################
# Detect if script is run from project root or inside syn/ directory
if {[file isdirectory "./src"]} {
    set ROOT_DIR "."
    set SYN_DIR  "./syn"
} elseif {[file isdirectory "../src"]} {
    set ROOT_DIR ".."
    set SYN_DIR  "."
} else {
    puts "==>FATAL: Cannot locate src/ directory. Run from project root or syn/ folder."
    exit 1
}

set SRC_DIR         "${ROOT_DIR}/src"
set CONSTRAINTS_DIR "${SYN_DIR}/constraints"

# Create output directories if they do not exist
foreach dir [list "./outputs" "./reports" "./logs" "./synopsys_cache"] {
    if {![file isdirectory $dir]} {
        file mkdir $dir
    }
}

redirect -file /dev/null {set start_time [clock seconds]}

set_app_var cache_file_chmod_octal 666
set_app_var cache_dir_chmod_octal 777

###################################################################
# STEP 1: Analyze & Elaborate Design
###################################################################
set elapsed_time [expr { ([clock seconds] - $start_time) / 60.0 }]
puts [format "##### Analyzing the Design. Runtime: %.2f mins #####" $elapsed_time]

# 1. Analyze the package first so types (e.g. cmplx_t) are available to all modules
if {[file exists ${SRC_DIR}/pkg/fft_pkg.sv]} {
    puts "==> Analyzing fft_pkg.sv..."
    analyze -format sverilog -library WORK ${SRC_DIR}/pkg/fft_pkg.sv
} else {
    puts "==>FATAL: ${SRC_DIR}/pkg/fft_pkg.sv not found! Exiting..."
    exit 1
}

# 2. Analyze the rest of the SystemVerilog RTL source files recursively
if {[file exists ${SRC_DIR}/top/${DESIGN_NAME}.sv]} {
    puts "==> Analyzing RTL hierarchy under ${SRC_DIR}..."
    analyze -autoread -recursive -verbose -rebuild -format sverilog -library WORK ${SRC_DIR}
} else {
    puts "==>FATAL: Top module ${SRC_DIR}/top/${DESIGN_NAME}.sv not found! Exiting..."
    exit 1
}

# 3. Elaborate top-level module
elaborate ${DESIGN_NAME} -library WORK
current_design ${DESIGN_NAME}

# 4. Link design
if {![eval {link}]} {
    puts "==>FATAL: Design Link Failed... Exiting..."
    exit 1
} else {
    link > ./reports/${DESIGN_NAME}.syn.link.rpt
}

###################################################################
# STEP 2: Synthesis Rules & Constraints
###################################################################
# Prevent tri-state/assign shorthand on ports
set_app_var verilogout_no_tri true
set_fix_multiple_port_nets -all
set_app_var uniquify_keep_original_design true

# Load timing & operating constraints
set CONSTRAINTS_FILE "${CONSTRAINTS_DIR}/fft_constraints.tcl"
if {[file exists $CONSTRAINTS_FILE]} {
    puts "==>INFORMATION: Sourcing constraints from: $CONSTRAINTS_FILE"
    source -echo -verbose $CONSTRAINTS_FILE
} else {
    puts "==>FATAL: Design Constraints file ($CONSTRAINTS_FILE) does not exist! Exiting..."
    exit 1
}

# Protect clock network from buffer insertion during logic synthesis
set_dont_touch_network [get_clocks]

# Operating conditions (adjust as per library PVT corner)
set_operating_conditions -analysis_type bc_wc -max tt0p8v25c

# ###################################################################
# # STEP 3: Path Groups & Critical Range Setup
# ###################################################################
# group_path -name inputs  -from [all_inputs]
# group_path -name output  -to   [all_outputs]
# group_path -name comb    -from [all_inputs] -to [all_outputs]
# group_path -name reg2reg -from [all_registers -clock_pins] -to [all_registers -data_pins]

# set_critical_range 2000 [current_design]

# ###################################################################
# # STEP 4: Compile / Optimization
# ###################################################################
# set elapsed_time [expr { ([clock seconds] - $start_time) / 60.0 }]
# puts [format "##### Running Compile Ultra. Runtime: %.2f mins #####" $elapsed_time]

# # Optimize datapath architectures and FSMs
# set_app_var fsm_auto_inferring true
# set_app_var fsm_enable_state_minimization true

# # compile_ultra performs advanced datapath optimization and boundary optimization
# compile_ultra

# set elapsed_time [expr { ([clock seconds] - $start_time) / 60.0 }]
# puts [format "##### Running Incremental Compile. Runtime: %.2f mins #####" $elapsed_time]

# compile_ultra -incremental

# ###################################################################
# # STEP 5: Re-group & Name Rules Cleanup
# ###################################################################
# group_path -name inputs  -from [all_inputs]
# group_path -name output  -to   [all_outputs]
# group_path -name comb    -from [all_inputs] -to [all_outputs]
# group_path -name reg2reg -from [all_registers -clock_pins] -to [all_registers -data_pins]

# define_name_rules standard_names \
#     -allowed "A-Za-z0-9_\[\]" \
#     -equal_ports_nets \
#     -remove_internal_net_bus \
#     -target_bus_naming_style "%s\[%d\]" \
#     -add_dummy_nets \
#     -flatten_multi_dimension_busses

# define_name_rules reg_names \
#     -type cell \
#     -map {{{"\]", "x"}, {"\[", "x"}}}

# change_names -hierarchy -verbose -rules reg_names      > ./logs/change_names_reg.log
# change_names -hierarchy -verbose -rules standard_names > ./logs/change_names_standard.log

# ###################################################################
# # STEP 6: Export Netlist, DDC & SDC
# ###################################################################
# set elapsed_time [expr { ([clock seconds] - $start_time) / 60.0 }]
# puts [format "##### Writing Outputs and Reports. Runtime: %.2f mins #####" $elapsed_time]

# write_file -format verilog -hierarchy -output ./outputs/${DESIGN_NAME}.vg
# write_file -format ddc     -hierarchy -output ./outputs/${DESIGN_NAME}.ddc

# set write_sdc_output_lumped_net_capacitance false
# set write_sdc_output_net_resistance false
# write_sdc -nosplit ./outputs/${DESIGN_NAME}.sdc

# ###################################################################
# # STEP 7: Generate Synthesis Reports
# ###################################################################
# report_area                                > ./reports/${DESIGN_NAME}.area.rpt
# report_reference -hierarchy -nosplit       > ./reports/${DESIGN_NAME}.ref.rpt
# report_qor                                 > ./reports/${DESIGN_NAME}.qor.rpt
# report_power -hierarchy -verbose -nosplit  > ./reports/${DESIGN_NAME}.power.rpt
# report_constraint -all_violators -nosplit  > ./reports/${DESIGN_NAME}.constraint.rpt
# check_design                               > ./reports/${DESIGN_NAME}.check_design.rpt
# check_timing                               > ./reports/${DESIGN_NAME}.check_timing.rpt
# report_fsm                                 > ./reports/${DESIGN_NAME}.fsm.rpt

# foreach_in_collection group [get_path_groups] {
#     set group_name [get_object_name $group]
#     set paths [get_timing_paths -group $group_name]
#     echo "Found path group: $group_name with [sizeof_collection $paths] paths."

#     if {[sizeof_collection $paths]} {
#         redirect -file ./reports/${DESIGN_NAME}.timing.${group_name}.rpt {
#             report_timing \
#                 -nosplit \
#                 -capacitance \
#                 -transition_time \
#                 -significant_digits 4 \
#                 -input_pins -nets -max_paths 1 \
#                 -group $group_name
#         }
#     }
# }

# set elapsed_time [expr { ([clock seconds] - $start_time) / 60.0 }]
# puts [format "##### Done. Runtime: %.2f mins, Memory Used: %.1f GB #####" $elapsed_time [expr [mem] / 1000000.0]]
