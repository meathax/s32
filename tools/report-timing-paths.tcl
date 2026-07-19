package require ::quartus::project
package require ::quartus::sta

set revision "Arcade-SegaSystem32"
if {[llength $quartus(args)] > 0} {
    set revision [lindex $quartus(args) 0]
}

project_open -revision $revision $revision
create_timing_netlist
read_sdc
update_timing_netlist

set reports {
    {fast96  {*general*0*.gpll~PLL_OUTPUT_COUNTER|divclk}}
    {sys48   {*general*1*.gpll~PLL_OUTPUT_COUNTER|divclk}}
    {sdram96 {SDRAM_CLK}}
    {hdmi148 {*pll_hdmi*counter*0*.output_counter|divclk}}
}

foreach report $reports {
    lassign $report label pattern
    set clocks [get_clocks $pattern]
    if {[get_collection_size $clocks] == 0} {
        post_message -type warning "No clock matched $label pattern: $pattern"
        continue
    }
    report_timing -setup -to_clock $clocks -npaths 30 -detail full_path \
        -file "output_files/timing-$label.rpt"
}

set fast_clock [get_clocks {*general*0*.gpll~PLL_OUTPUT_COUNTER|divclk}]
report_timing -setup -from_clock $fast_clock -to_clock $fast_clock \
    -npaths 200 -nworst 1 -detail full_path \
    -file "output_files/timing-fast96-internal.rpt"

set sdram_clock [get_clocks {SDRAM_CLK}]
report_timing -setup -from_clock $fast_clock -to_clock $sdram_clock \
    -npaths 100 -nworst 1 -detail full_path \
    -file "output_files/timing-sdram-output.rpt"
report_timing -hold -from_clock $sdram_clock -to_clock $fast_clock \
    -npaths 100 -nworst 1 -detail full_path \
    -file "output_files/timing-sdram-input.rpt"
report_timing -setup -from_clock $sdram_clock -to_clock $fast_clock \
    -npaths 100 -nworst 1 -detail full_path \
    -file "output_files/timing-sdram-input-setup.rpt"

delete_timing_netlist
project_close
