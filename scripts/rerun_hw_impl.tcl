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
set project_file [file join $build_dir ${project_name}.xpr]

if {![file exists $project_file]} {
  puts "ERROR: hardware Vivado project not found at $project_file"
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

set impl_resume 0
if {[info exists ::env(TRAFFIC_REPLAY_IMPL_RESUME)] && $::env(TRAFFIC_REPLAY_IMPL_RESUME) ne ""} {
  set impl_resume $::env(TRAFFIC_REPLAY_IMPL_RESUME)
}
if {![string is integer -strict $impl_resume] || ($impl_resume != 0 && $impl_resume != 1)} {
  puts "ERROR: TRAFFIC_REPLAY_IMPL_RESUME must be 0 or 1"
  exit 1
}
if {[lsearch -exact {place_design phys_opt_design route_design write_bitstream} $impl_to_step] < 0} {
  puts "ERROR: TRAFFIC_REPLAY_IMPL_TO_STEP must be place_design, phys_opt_design, route_design, or write_bitstream"
  exit 1
}

open_project $project_file
set impl_runs [get_runs -quiet impl_1]
if {[llength $impl_runs] == 0} {
  puts "ERROR: impl_1 run does not exist in $project_file"
  exit 1
}

set impl_strategy "Performance_ExplorePostRoutePhysOpt"
if {[info exists ::env(TRAFFIC_REPLAY_IMPL_STRATEGY)] && $::env(TRAFFIC_REPLAY_IMPL_STRATEGY) ne ""} {
  set impl_strategy $::env(TRAFFIC_REPLAY_IMPL_STRATEGY)
}
if {[catch {set_property strategy $impl_strategy $impl_runs} strategy_err]} {
  puts "WARNING: failed to set implementation strategy $impl_strategy: $strategy_err"
}

if {[info exists ::env(TRAFFIC_REPLAY_ROUTE_DIRECTIVE)] &&
    $::env(TRAFFIC_REPLAY_ROUTE_DIRECTIVE) ne ""} {
  set route_directive $::env(TRAFFIC_REPLAY_ROUTE_DIRECTIVE)
  set valid_route_directives {
    Default Explore AggressiveExplore NoTimingRelaxation MoreGlobalIterations
    HigherDelayCost AdvancedSkewModeling AlternateCLBRouting RuntimeOptimized Quick
  }
  if {[lsearch -exact $valid_route_directives $route_directive] < 0} {
    puts "ERROR: unsupported TRAFFIC_REPLAY_ROUTE_DIRECTIVE: $route_directive"
    exit 1
  }
  set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE $route_directive $impl_runs
  puts "Implementation route directive: $route_directive"
}

if {[info exists ::env(TRAFFIC_REPLAY_INCREMENTAL_CHECKPOINT)] && $::env(TRAFFIC_REPLAY_INCREMENTAL_CHECKPOINT) ne ""} {
  set inc_dcp [file normalize $::env(TRAFFIC_REPLAY_INCREMENTAL_CHECKPOINT)]
  if {![file exists $inc_dcp]} {
    puts "ERROR: incremental checkpoint does not exist: $inc_dcp"
    exit 1
  }
  if {[catch {set_property incremental_checkpoint $inc_dcp $impl_runs} inc_err]} {
    puts "ERROR: failed to set incremental checkpoint $inc_dcp: $inc_err"
    exit 1
  }
  puts "Implementation incremental checkpoint: $inc_dcp"
} else {
  # A run property survives reset_run.  Clear it explicitly so an omitted
  # environment variable always requests a genuinely non-incremental build.
  set_property incremental_checkpoint "" $impl_runs
  puts "Implementation incremental checkpoint: disabled"
}

set synth_status [get_property STATUS [get_runs synth_1]]
puts "Hardware synthesis status: $synth_status"
if {[string first "synth_design Complete" $synth_status] < 0} {
  puts "ERROR: synth_1 is not complete; run hwbit first for a full build"
  exit 1
}

if {!$impl_resume} {
  reset_run impl_1
} else {
  puts "Resuming implementation from status: [get_property STATUS [get_runs impl_1]]"
}
launch_runs impl_1 -to_step $impl_to_step -jobs $vivado_jobs
wait_on_run impl_1

set impl_status [get_property STATUS [get_runs impl_1]]
puts "Hardware implementation status: $impl_status"
set expected_status $impl_to_step
switch $impl_to_step {
  place_design     { set expected_status "Not started phys_opt_design" }
  phys_opt_design  { set expected_status "Not started route_design" }
  route_design     { set expected_status "Not started" }
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
  set step_checkpoint [file join $build_dir ${project_name}.runs impl_1 traffic_replay_bd_wrapper_${checkpoint_suffix}.dcp]
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
