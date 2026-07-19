derive_pll_clocks
derive_clock_uncertainty

# core specific constraints


#**************************************************************
# Sega System 32 core: SDRAM timing (CL2 @ 96.634615 MHz, 180deg clock)
#**************************************************************
set sdram_fwd_pin [get_pins -nowarn -compatibility_mode \
    {*|pll|pll_inst|altera_pll_i|*[2].*|divclk}]
set sdram_mem_clk [get_clocks -nowarn \
    {*|pll|pll_inst|altera_pll_i|*[0].*|divclk}]

# Fail the timing flow instead of silently releasing an unconstrained SDRAM bus
# if Quartus changes the generated PLL hierarchy.
if {[get_collection_size $sdram_fwd_pin] != 1} {
    error "Expected exactly one PLL outclk2 pin for the forwarded SDRAM clock"
}
if {[get_collection_size $sdram_mem_clk] != 1} {
    error "Expected exactly one PLL outclk0 clock for the SDRAM controller"
}

create_generated_clock -name SDRAM_CLK -source $sdram_fwd_pin \
    [get_ports SDRAM_CLK]

# board + chip delays (typical MiSTer SDRAM module, -7 grade)
set_input_delay  -clock SDRAM_CLK -max 6.4 [get_ports SDRAM_DQ[*]]
set_input_delay  -clock SDRAM_CLK -min 3.2 [get_ports SDRAM_DQ[*]]
set_output_delay -clock SDRAM_CLK -max 1.5 \
    [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH \
                SDRAM_nCS SDRAM_nCAS SDRAM_nRAS SDRAM_nWE SDRAM_CKE}]
set_output_delay -clock SDRAM_CLK -min -0.8 \
    [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH \
                SDRAM_nCS SDRAM_nCAS SDRAM_nRAS SDRAM_nWE SDRAM_CKE}]
set_multicycle_path -setup -end -from [get_clocks SDRAM_CLK] \
    -to $sdram_mem_clk 2
set_multicycle_path -hold -end -from [get_clocks SDRAM_CLK] \
    -to $sdram_mem_clk 1

# The V60/V70 core is clock-enabled at most every second clk_sys edge (every
# third edge in System 32 mode).  Restrict the exception to internal CPU
# register-to-register paths so asynchronous IRQ/bus inputs remain single-cycle.
set v60_regs [get_registers -nowarn {*|s32_v60:v60|*}]
if {[get_collection_size $v60_regs] == 0} {
    error "Expected V60 registers for the CPU clock-enable constraint"
}
set_multicycle_path -setup 2 -from $v60_regs -to $v60_regs
set_multicycle_path -hold  1 -from $v60_regs -to $v60_regs

# Sprite words 0..6 are loaded at least two fetch clocks before decode; word 7
# is intentionally excluded because clip commands consume it on the very next
# decode edge.  x0/y0 are latched before the scale/row/pixel states consume
# them.  These paths are state-exclusive, while the sprite FSM still accepts
# and emits one pixel per fast clock in R_PIXEL.  A two-cycle requirement
# describes the minimum real separation without reducing renderer throughput.
set sprite_deferred_sources [get_registers -nowarn \
    {*|s32_sprite:sprite|sw[0][*] *|s32_sprite:sprite|sw[1][*] \
     *|s32_sprite:sprite|sw[2][*] *|s32_sprite:sprite|sw[3][*] \
     *|s32_sprite:sprite|sw[4][*] *|s32_sprite:sprite|sw[5][*] \
     *|s32_sprite:sprite|sw[6][*] *|s32_sprite:sprite|x0[*] \
     *|s32_sprite:sprite|y0[*]}]
set sprite_regs [get_registers -nowarn {*|s32_sprite:sprite|*}]
if {[get_collection_size $sprite_deferred_sources] == 0 ||
    [get_collection_size $sprite_regs] == 0} {
    error "Expected sprite registers for the state-exclusive timing constraint"
}
set_multicycle_path -setup 2 -from $sprite_deferred_sources -to $sprite_regs
set_multicycle_path -hold  1 -from $sprite_deferred_sources -to $sprite_regs
