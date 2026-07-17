derive_pll_clocks
derive_clock_uncertainty

# core specific constraints


#**************************************************************
# Sega System 32 core: SDRAM timing (CL2 @ 96.634615 MHz, -90deg clock)
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
