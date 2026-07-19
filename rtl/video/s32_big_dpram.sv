//============================================================================
//  Large 16-bit true-dual-port block RAM used by System 32 work, sprite and
//  video RAM.  Quartus 17 expands the equivalent unpacked-array RTL into a
//  multi-gigabyte logic netlist instead of inferring Cyclone V M10Ks.
//
//  The Intel primitive is confined to integrated synthesis.  Simulation with
//  Icarus, Verilator, or ModelSim uses the cycle-equivalent behavioural model
//  and does not depend on altera_mf simulation libraries.
//============================================================================

module s32_big_dpram #(
    parameter integer ADDR_WIDTH = 16,
    parameter integer NUM_WORDS  = (1 << ADDR_WIDTH),
    // Asynchronous-clock collisions have no deterministic old/new ordering
    // in Cyclone V hardware.  Such clients select DONT_CARE to avoid an
    // invalid mixed-port feed-through request; same-clock clients keep OLD.
    parameter         MIXED_RDW_MODE = "OLD_DATA"
) (
    input                       clock_a,
    input      [ADDR_WIDTH-1:0] address_a,
    input                [15:0] data_a,
    input                 [1:0] byteena_a,
    input                       wren_a,
    output               [15:0] q_a,

    input                       clock_b,
    input      [ADDR_WIDTH-1:0] address_b,
    input                [15:0] data_b,
    input                 [1:0] byteena_b,
    input                       wren_b,
    output               [15:0] q_b
);

`ifdef ALTERA_RESERVED_QIS
altsyncram ram (
    .clock0(clock_a),
    .address_a(address_a),
    .data_a(data_a),
    .byteena_a(byteena_a),
    .wren_a(wren_a),
    .q_a(q_a),

    .clock1(clock_b),
    .address_b(address_b),
    .data_b(data_b),
    .byteena_b(byteena_b),
    .wren_b(wren_b),
    .q_b(q_b),

    .aclr0(1'b0),
    .aclr1(1'b0),
    .addressstall_a(1'b0),
    .addressstall_b(1'b0),
    .clocken0(1'b1),
    .clocken1(1'b1),
    .clocken2(1'b1),
    .clocken3(1'b1),
    .eccstatus(),
    .rden_a(1'b1),
    .rden_b(1'b1)
);
defparam
    ram.numwords_a = NUM_WORDS,
    ram.widthad_a = ADDR_WIDTH,
    ram.width_a = 16,
    ram.numwords_b = NUM_WORDS,
    ram.widthad_b = ADDR_WIDTH,
    ram.width_b = 16,
    ram.address_reg_b = "CLOCK1",
    ram.clock_enable_input_a = "BYPASS",
    ram.clock_enable_input_b = "BYPASS",
    ram.clock_enable_output_a = "BYPASS",
    ram.clock_enable_output_b = "BYPASS",
    ram.indata_reg_b = "CLOCK1",
    ram.intended_device_family = "Cyclone V",
    ram.lpm_type = "altsyncram",
    ram.operation_mode = "BIDIR_DUAL_PORT",
    ram.outdata_aclr_a = "NONE",
    ram.outdata_aclr_b = "NONE",
    ram.outdata_reg_a = "UNREGISTERED",
    ram.outdata_reg_b = "UNREGISTERED",
    ram.power_up_uninitialized = "FALSE",
    ram.read_during_write_mode_mixed_ports = MIXED_RDW_MODE,
    // Cyclone V true-dual-port M10Ks require NEW_DATA on each bidirectional
    // port.  Core clients ignore q on a write cycle; mixed-port collisions
    // retain OLD_DATA, which is the only observable collision case here.
    ram.read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ",
    ram.read_during_write_mode_port_b = "NEW_DATA_NO_NBE_READ",
    ram.width_byteena_a = 2,
    ram.width_byteena_b = 2,
    ram.wrcontrol_wraddress_reg_b = "CLOCK1";
`else
reg [15:0] mem [0:NUM_WORDS-1];
reg [15:0] q_a_r;
reg [15:0] q_b_r;
assign q_a = q_a_r;
assign q_b = q_b_r;

integer __ram_init;
initial begin
    for (__ram_init = 0; __ram_init < NUM_WORDS; __ram_init = __ram_init + 1)
        mem[__ram_init] = 16'h0000;
end

// Stable simulation observation API used by full-core benches.  Keep tests
// independent of whether this module is implemented as an array or a vendor
// primitive in future revisions.
function automatic [15:0] sim_peek(input [ADDR_WIDTH-1:0] addr);
    sim_peek = mem[addr];
endfunction

always @(posedge clock_a) begin
    q_a_r <= mem[address_a];
    if (wren_a) begin
        if (byteena_a[0]) mem[address_a][7:0]  <= data_a[7:0];
        if (byteena_a[1]) mem[address_a][15:8] <= data_a[15:8];
    end
end

always @(posedge clock_b) begin
    q_b_r <= mem[address_b];
    if (wren_b) begin
        if (byteena_b[0]) mem[address_b][7:0]  <= data_b[7:0];
        if (byteena_b[1]) mem[address_b][15:8] <= data_b[15:8];
    end
end
`endif

endmodule

//============================================================================
//  Byte-wide, common-clock true-dual-port block RAM.
//
//  System 32's Z80/V60 shared RAM and the V25 mailbox both use registered
//  reads.  Quartus 17 does not reliably infer an M10K for the equivalent
//  two-write unpacked-array RTL, so synthesis uses altsyncram explicitly.
//  The behavioural branch keeps the original one-cycle, old-data collision
//  semantics: both reads sample the pre-write word, and an inactive read
//  enable holds that port's q output.  Simultaneous writes to one address are
//  forbidden because the physical M10K result is undefined.
//============================================================================

module s32_byte_dpram #(
    parameter integer ADDR_WIDTH = 13,
    parameter integer NUM_WORDS  = (1 << ADDR_WIDTH),
    parameter         POWER_UP_UNINITIALIZED = "TRUE"
) (
    input                       clock,

    input      [ADDR_WIDTH-1:0] address_a,
    input                 [7:0] data_a,
    input                       rden_a,
    input                       wren_a,
    output                [7:0] q_a,

    input      [ADDR_WIDTH-1:0] address_b,
    input                 [7:0] data_b,
    input                       rden_b,
    input                       wren_b,
    output                [7:0] q_b
);

`ifdef ALTERA_RESERVED_QIS
altsyncram ram (
    .clock0(clock),
    .address_a(address_a),
    .data_a(data_a),
    .rden_a(rden_a),
    .wren_a(wren_a),
    .q_a(q_a),

    .clock1(clock),
    .address_b(address_b),
    .data_b(data_b),
    .rden_b(rden_b),
    .wren_b(wren_b),
    .q_b(q_b),

    .aclr0(1'b0),
    .aclr1(1'b0),
    .addressstall_a(1'b0),
    .addressstall_b(1'b0),
    .clocken0(1'b1),
    .clocken1(1'b1),
    .clocken2(1'b1),
    .clocken3(1'b1),
    .eccstatus()
);
defparam
    ram.numwords_a = NUM_WORDS,
    ram.widthad_a = ADDR_WIDTH,
    ram.width_a = 8,
    ram.numwords_b = NUM_WORDS,
    ram.widthad_b = ADDR_WIDTH,
    ram.width_b = 8,
    ram.address_reg_b = "CLOCK1",
    ram.clock_enable_input_a = "BYPASS",
    ram.clock_enable_input_b = "BYPASS",
    ram.clock_enable_output_a = "BYPASS",
    ram.clock_enable_output_b = "BYPASS",
    ram.indata_reg_b = "CLOCK1",
    ram.intended_device_family = "Cyclone V",
    ram.lpm_type = "altsyncram",
    ram.operation_mode = "BIDIR_DUAL_PORT",
    ram.outdata_aclr_a = "NONE",
    ram.outdata_aclr_b = "NONE",
    ram.outdata_reg_a = "UNREGISTERED",
    ram.outdata_reg_b = "UNREGISTERED",
    ram.power_up_uninitialized = POWER_UP_UNINITIALIZED,
    ram.read_during_write_mode_mixed_ports = "OLD_DATA",
    // Cyclone V true-dual-port M10Ks require new data on a port's own write
    // cycle.  Both clients discard q on their own writes; mixed-port reads,
    // which are observable, retain the original RTL's old-data behavior.
    ram.read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ",
    ram.read_during_write_mode_port_b = "NEW_DATA_NO_NBE_READ",
    ram.wrcontrol_wraddress_reg_b = "CLOCK1";
`else
reg [7:0] mem [0:NUM_WORDS-1];
reg [7:0] q_a_r;
reg [7:0] q_b_r;
assign q_a = q_a_r;
assign q_b = q_b_r;

function automatic [7:0] sim_peek(input [ADDR_WIDTH-1:0] addr);
    sim_peek = mem[addr];
endfunction

always @(posedge clock) begin
    if (rden_a) q_a_r <= mem[address_a];
    if (rden_b) q_b_r <= mem[address_b];
    if (wren_a) mem[address_a] <= data_a;
    if (wren_b) mem[address_b] <= data_b;
end
`endif

endmodule
