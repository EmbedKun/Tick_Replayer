set script_dir [file dirname [file normalize [info script]]]
set repo_dir [file normalize [file join $script_dir ..]]
set reports_dir [file join $repo_dir reports]
file mkdir $reports_dir

set traffic_replay_vivado_threads 1
if {[info exists ::env(TRAFFIC_REPLAY_VIVADO_THREADS)] && $::env(TRAFFIC_REPLAY_VIVADO_THREADS) ne ""} {
  set traffic_replay_vivado_threads $::env(TRAFFIC_REPLAY_VIVADO_THREADS)
}
if {![string is integer -strict $traffic_replay_vivado_threads] || $traffic_replay_vivado_threads < 1} {
  puts "ERROR: TRAFFIC_REPLAY_VIVADO_THREADS must be a positive integer"
  exit 1
}
set_param general.maxThreads $traffic_replay_vivado_threads

if {[info exists ::env(TRAFFIC_REPLAY_HW_BUILD_ROOT)] && $::env(TRAFFIC_REPLAY_HW_BUILD_ROOT) ne ""} {
  set hw_build_root [file normalize $::env(TRAFFIC_REPLAY_HW_BUILD_ROOT)]
} else {
  set hw_build_root [file join $repo_dir build]
}

set build_dir [file join $hw_build_root vivado_hw]
set project_name traffic_replay_hw
set bd_name traffic_replay_bd
set project_file [file join $build_dir ${project_name}.xpr]

if {![file exists $project_file]} {
  puts "ERROR: hardware Vivado project not found at $project_file"
  puts "Run bash scripts/run_vivado.sh hwbd first."
  exit 1
}

set vivado_jobs 1
if {[info exists ::env(TRAFFIC_REPLAY_VIVADO_JOBS)] && $::env(TRAFFIC_REPLAY_VIVADO_JOBS) ne ""} {
  set vivado_jobs $::env(TRAFFIC_REPLAY_VIVADO_JOBS)
}

set impl_to_step "write_bitstream"
if {[info exists ::env(TRAFFIC_REPLAY_IMPL_TO_STEP)] && $::env(TRAFFIC_REPLAY_IMPL_TO_STEP) ne ""} {
  set impl_to_step $::env(TRAFFIC_REPLAY_IMPL_TO_STEP)
}
if {[lsearch -exact {place_design phys_opt_design route_design write_bitstream} $impl_to_step] < 0} {
  puts "ERROR: TRAFFIC_REPLAY_IMPL_TO_STEP must be place_design, phys_opt_design, route_design, or write_bitstream"
  exit 1
}

set synth_only 0
if {[info exists ::env(TRAFFIC_REPLAY_SYNTH_ONLY)] && $::env(TRAFFIC_REPLAY_SYNTH_ONLY) ne ""} {
  set synth_only $::env(TRAFFIC_REPLAY_SYNTH_ONLY)
}
if {![string is integer -strict $synth_only] || ($synth_only != 0 && $synth_only != 1)} {
  puts "ERROR: TRAFFIC_REPLAY_SYNTH_ONLY must be 0 or 1"
  exit 1
}

open_project $project_file
set impl_runs [get_runs -quiet impl_1]
set impl_strategy "Performance_ExplorePostRoutePhysOpt"
if {[llength $impl_runs] > 0} {
  if {[info exists ::env(TRAFFIC_REPLAY_IMPL_STRATEGY)] && $::env(TRAFFIC_REPLAY_IMPL_STRATEGY) ne ""} {
    set impl_strategy $::env(TRAFFIC_REPLAY_IMPL_STRATEGY)
  }
  if {[catch {set_property strategy $impl_strategy $impl_runs} strategy_err]} {
    puts "WARNING: failed to set implementation strategy $impl_strategy: $strategy_err"
  }
}
if {[info exists ::env(TRAFFIC_REPLAY_INCREMENTAL_CHECKPOINT)] && $::env(TRAFFIC_REPLAY_INCREMENTAL_CHECKPOINT) ne ""} {
  set inc_dcp [file normalize $::env(TRAFFIC_REPLAY_INCREMENTAL_CHECKPOINT)]
  if {![file exists $inc_dcp]} {
    puts "ERROR: incremental checkpoint does not exist: $inc_dcp"
    exit 1
  }
  if {[llength $impl_runs] == 0} {
    puts "ERROR: impl_1 run does not exist; cannot set incremental checkpoint"
    exit 1
  }
  if {[catch {set_property incremental_checkpoint $inc_dcp $impl_runs} inc_err]} {
    puts "ERROR: failed to set incremental checkpoint $inc_dcp: $inc_err"
    exit 1
  }
  puts "Implementation incremental checkpoint: $inc_dcp"
} else {
  if {[llength $impl_runs] > 0} {
    set_property incremental_checkpoint "" $impl_runs
    puts "Implementation incremental checkpoint: disabled"
  }
}
set wrapper_file [file join $build_dir $project_name.gen sources_1 bd $bd_name hdl ${bd_name}_wrapper.v]
if {[file exists $wrapper_file] && [llength [get_files -quiet $wrapper_file]] == 0} {
  add_files -norecurse $wrapper_file
}
set_property top ${bd_name}_wrapper [current_fileset]
update_compile_order -fileset sources_1

reset_run synth_1
launch_runs synth_1 -jobs $vivado_jobs
wait_on_run synth_1

set synth_status [get_property STATUS [get_runs synth_1]]
puts "Hardware synthesis status: $synth_status"
if {[string first "synth_design Complete" $synth_status] < 0} {
  puts "ERROR: hardware synthesis did not complete cleanly"
  exit 1
}

open_run synth_1
report_utilization -file [file join $reports_dir hw_synth_utilization.rpt]
report_timing_summary -file [file join $reports_dir hw_synth_timing_summary.rpt]
close_design

if {$synth_only} {
  puts "Synthesis-only build completed"
  exit 0
}

reset_run impl_1
launch_runs impl_1 -to_step $impl_to_step -jobs $vivado_jobs
wait_on_run impl_1

set impl_status [get_property STATUS [get_runs impl_1]]
puts "Hardware implementation status: $impl_status"
set expected_status $impl_to_step
switch $impl_to_step {
  place_design     { set expected_status "Not started phys_opt_design" }
  phys_opt_design  { set expected_status "Not started route_design" }
  route_design     { set expected_status "Not started write_bitstream" }
  write_bitstream  { set expected_status "write_bitstream Complete" }
}
if {[string first $expected_status $impl_status] < 0} {
  puts "ERROR: hardware implementation/bitstream did not complete cleanly"
  exit 1
}

if {$impl_to_step eq "write_bitstream"} {
  open_run impl_1
} else {
  set checkpoint_suffix "placed"
  switch $impl_to_step {
    place_design    { set checkpoint_suffix "placed" }
    phys_opt_design { set checkpoint_suffix "physopt" }
    route_design    { set checkpoint_suffix "routed" }
  }
  set step_checkpoint [file join $build_dir ${project_name}.runs impl_1 ${bd_name}_wrapper_${checkpoint_suffix}.dcp]
  if {![file exists $step_checkpoint]} {
    puts "ERROR: implementation checkpoint was not generated: $step_checkpoint"
    exit 1
  }
  open_checkpoint $step_checkpoint
}
report_utilization -file [file join $reports_dir hw_impl_utilization.rpt]
report_timing_summary -file [file join $reports_dir hw_impl_timing_summary.rpt]
if {$impl_to_step ne "write_bitstream"} {
  puts "Implementation stopped after requested step: $impl_to_step"
  exit 0
}
set bitfiles [glob -nocomplain [file join $build_dir ${project_name}.runs impl_1 *.bit]]
if {[llength $bitfiles] > 0} {
  puts "Bitstream: [lindex $bitfiles 0]"
}
exit
