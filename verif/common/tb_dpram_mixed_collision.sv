// Mixed-port same-address collision on the renderer read port of
// s32_big_dpram (sprite_ram, video_ram).
//
// Both RAMs run port A on clk_sys (V60 writes the sprite object list / VRAM)
// and port B on clk_ram (sprite walker / tilemap fetch), with
// read_during_write_mode_mixed_ports = DONT_CARE.  A Cyclone V M10K returns
// UNDEFINED bits when port B reads the address port A is writing in the same
// cycle.  The System 32 PCB cannot produce that case at all: the CPU and the
// video/sprite chips share one SRAM through the bus controller, so their
// accesses are serialised.  One corrupted descriptor word is one object drawn
// at the wrong position, or not drawn, for one frame.
//
// This bench reproduces the collision with the real clock relationship
// (clk_sys is a phase-related divide-by-two of clk_ram) and runs two DUTs
// from identical stimulus:
//   dut_fix  - MIXED_COLLISION_FWD = 1 (production configuration)
//   dut_ctl  - MIXED_COLLISION_FWD = 0 (the unresolved pre-fix path)
// Both have SIM_COLLISION_POISON = 1, which drives the raw array output to a
// word that is neither the old nor the new value on a collision, standing in
// for the M10K's undefined read.  The control must show the poison and the
// production configuration must not; a bench that only ran the fixed DUT
// could pass without the hazard ever having been modelled.

`timescale 1ns/1ps

module tb_dpram_mixed_collision;

localparam [15:0] POISON = 16'hBAD0;   // matches SIM_COLLISION_POISON

// clk_b = clk_ram (96.6 MHz modelled as 10 ns), clk_a = clk_sys = clk_b/2,
// rising edges aligned exactly as the PLL emits them.
reg clk_b = 1'b1;
reg clk_a = 1'b1;
always #5 clk_b = ~clk_b;
always #10 clk_a = ~clk_a;

reg  [3:0]  addr_a = 4'h0;
reg  [15:0] data_a = 16'h0000;
reg  [1:0]  be_a   = 2'b00;
reg         we_a   = 1'b0;
reg  [3:0]  addr_b = 4'h0;

wire [15:0] q_a_fix, q_b_fix;
wire [15:0] q_a_ctl, q_b_ctl;

s32_big_dpram #(
    .ADDR_WIDTH(4), .NUM_WORDS(16),
    .MIXED_RDW_MODE("DONT_CARE"), .PORT_B_READ_ONLY(1'b1),
    .SIM_COLLISION_POISON(1'b1)
) dut_fix (
    .clock_a(clk_a), .address_a(addr_a), .data_a(data_a),
    .byteena_a(be_a), .wren_a(we_a), .q_a(q_a_fix),
    .clock_b(clk_b), .address_b(addr_b), .data_b(16'h0000),
    .byteena_b(2'b00), .wren_b(1'b0), .q_b(q_b_fix)
);

s32_big_dpram #(
    .ADDR_WIDTH(4), .NUM_WORDS(16),
    .MIXED_RDW_MODE("DONT_CARE"), .PORT_B_READ_ONLY(1'b1),
    .MIXED_COLLISION_FWD(1'b0), .SIM_COLLISION_POISON(1'b1)
) dut_ctl (
    .clock_a(clk_a), .address_a(addr_a), .data_a(data_a),
    .byteena_a(be_a), .wren_a(we_a), .q_a(q_a_ctl),
    .clock_b(clk_b), .address_b(addr_b), .data_b(16'h0000),
    .byteena_b(2'b00), .wren_b(1'b0), .q_b(q_b_ctl)
);

integer fails = 0;

task expect_eq(input [15:0] got, input [15:0] want, input [255:0] what);
    begin
        if (got !== want) begin
            $display("DPRAM COLLISION FAIL: %0s got=%04x want=%04x", what, got, want);
            fails = fails + 1;
        end
    end
endtask

task expect_ne(input [15:0] got, input [15:0] bad, input [255:0] what);
    begin
        if (got === bad) begin
            $display("DPRAM COLLISION FAIL: %0s got=%04x (must differ)", what, got);
            fails = fails + 1;
        end
    end
endtask

// One port-A word write, aligned to the clk_a grid the PLL produces.
task write_a(input [3:0] a, input [15:0] d, input [1:0] be);
    begin
        @(posedge clk_a);
        addr_a = a; data_a = d; be_a = be; we_a = 1'b1;
        @(posedge clk_a);          // write commits on this edge
        #1 we_a = 1'b0; be_a = 2'b00;
    end
endtask

initial begin
    addr_b = 4'h5;
    repeat (4) @(posedge clk_a);

    // ---- seed the location, no collision (port B parked elsewhere) ----
    addr_b = 4'h0;
    write_a(4'h5, 16'h1234, 2'b11);
    addr_b = 4'h5;
    @(posedge clk_b); #1;
    expect_eq(q_b_fix, 16'h1234, "seed visible on port B (fixed)");
    expect_eq(q_b_ctl, 16'h1234, "seed visible on port B (control)");

    // ---- collision: port B reads 0x5 while port A writes 0x5 ----
    // addr_b already 0x5 and held across both clock_b edges of the write.
    @(posedge clk_a);
    addr_a = 4'h5; data_a = 16'hC0DE; be_a = 2'b11; we_a = 1'b1;

    @(posedge clk_b); #1;          // first clock_b edge inside the write window
    expect_eq(q_b_ctl, POISON,     "control must expose the undefined read (edge 1)");
    expect_ne(q_b_fix, POISON,     "fixed must not expose the undefined read (edge 1)");
    expect_eq(q_b_fix, 16'hC0DE,   "fixed forwards the port-A word (edge 1)");

    @(posedge clk_b); #1;          // commit edge (coincides with posedge clk_a)
    expect_eq(q_b_ctl, POISON,     "control must expose the undefined read (edge 2)");
    expect_eq(q_b_fix, 16'hC0DE,   "fixed forwards the port-A word (edge 2)");
    we_a = 1'b0; be_a = 2'b00;

    @(posedge clk_b); #1;          // write committed, no collision
    expect_eq(q_b_fix, 16'hC0DE,   "committed word after collision (fixed)");
    expect_eq(q_b_ctl, 16'hC0DE,   "committed word after collision (control)");

    // ---- no collision while port A writes a different address ----
    addr_b = 4'h5;
    @(posedge clk_a);
    addr_a = 4'h6; data_a = 16'h9999; be_a = 2'b11; we_a = 1'b1;
    @(posedge clk_b); #1;
    expect_eq(q_b_fix, 16'hC0DE,   "unrelated write must not forward (fixed)");
    expect_eq(q_b_ctl, 16'hC0DE,   "unrelated write must not poison (control)");
    @(posedge clk_b); #1;
    expect_eq(q_b_fix, 16'hC0DE,   "unrelated write must not forward (fixed, edge 2)");
    we_a = 1'b0; be_a = 2'b00;

    // ---- partial-byteena collision: the written lane is resolved ----
    // The unwritten lane still comes from the array's undefined output.  That
    // residual is documented in s32_big_dpram.sv; closing it needs port A on
    // clk_ram so the pair can use same-clock OLD_DATA.  Assert only what the
    // forward actually guarantees so this test cannot drift into claiming more.
    @(posedge clk_b); #1;
    addr_b = 4'h5;
    @(posedge clk_a);
    addr_a = 4'h5; data_a = 16'h77ff; be_a = 2'b01; we_a = 1'b1;
    @(posedge clk_b); #1;
    expect_eq(q_b_fix[7:0], 8'hff, "written lane resolved on partial write (fixed)");
    expect_eq(q_b_ctl, POISON,     "control still undefined on partial write");
    @(posedge clk_b); #1;
    we_a = 1'b0; be_a = 2'b00;

    // ---- port A read path unchanged by the forward ----
    @(posedge clk_a); #1;
    addr_a = 4'h6;
    @(posedge clk_a); #1;
    expect_eq(q_a_fix, 16'h9999, "port-A read unchanged by the forward");
    expect_eq(q_a_ctl, 16'h9999, "port-A read unchanged (control)");

    if (fails == 0) $display("DPRAM MIXED COLLISION PASS");
    else begin
        $display("DPRAM MIXED COLLISION: %0d failure(s)", fails);
        $fatal(1);
    end
    $finish;
end

endmodule
