package require ::quartus::project
package require ::quartus::sta

set revision "s32Alien3"
if {[llength $quartus(args)] > 0} {
    set revision [lindex $quartus(args) 0]
}

project_open -revision $revision $revision
create_timing_netlist
read_sdc
update_timing_netlist

set slow_100c ""
foreach_in_collection op [get_available_operating_conditions] {
    set model [get_operating_conditions_info $op -model]
    set temperature [get_operating_conditions_info $op -temperature]
    if {[string equal -nocase $model "slow"] && $temperature == 100} {
        set slow_100c $op
        break
    }
}
if {$slow_100c eq ""} {
    error "Alien 3 timing diagnostic: Slow 100C operating condition is missing"
}

set_operating_conditions $slow_100c
update_timing_netlist
report_timing -setup -npaths 100 -nworst 2 -detail full_path \
    -file output_files/timing-alien3-critical-slow100.rpt

delete_timing_netlist
project_close
