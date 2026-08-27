`timescale 1ns/1ps

module tb_radm_motor_mailbox;
reg clk = 0;
reg rst = 1;
reg cs = 0;
reg we = 0;
reg [4:0] addr = 0;
reg [7:0] wdata = 0;
wire [7:0] rdata;
wire [7:0] pc_out, pd_out, pg_out, ph_out, dir_out;
wire [7:0] motor_data;
wire motor_selected;
wire [7:0] pc_in = motor_selected ? motor_data : 8'ha5;

always #5 clk = ~clk;

s32_io5296 io (
    .clk(clk), .rst(rst), .cs(cs), .we(we), .addr(addr),
    .wdata(wdata), .rdata(rdata),
    .in_pa(8'hff), .in_pb(8'hff), .in_pc(pc_in),
    .in_pe(8'hff), .in_pf(8'hff),
    .out_pc(pc_out), .out_pd(pd_out), .out_pg(pg_out), .out_ph(ph_out),
    .dir_out(dir_out), .cnt0(), .cnt1(), .cnt2()
);

s32_radm_motor_mailbox #(.STARTUP_CYCLES(4), .RESPONSE_CYCLES(3)) motor (
    .clk(clk), .rst(rst), .enable(1'b1),
    .address(pg_out), .data_out(pc_out), .data_output_en(dir_out[2]),
    .strobe_n(pd_out[4]), .data_in(motor_data), .selected(motor_selected)
);

task write_reg(input [4:0] reg_addr, input [7:0] value);
begin
    @(negedge clk); addr = reg_addr; wdata = value; cs = 1; we = 1;
    @(negedge clk); cs = 0; we = 0;
end
endtask

task read_reg(input [4:0] reg_addr, output [7:0] value);
begin
    @(negedge clk); addr = reg_addr; cs = 1; we = 0;
    @(negedge clk); value = rdata; cs = 0;
end
endtask

reg [7:0] value;
initial begin
    repeat (3) @(posedge clk);
    rst = 0;

    // Preload D high while it is an input, then expose D/G/H as outputs.
    write_reg(5'h3, 8'h10);
    write_reg(5'hf, 8'hc8);
    if (pd_out !== 8'h10) $fatal(1, "DIR did not expose port-D latch");

    // The external C pins remain visible while DIR.C is zero.
    write_reg(5'h6, 8'h40);
    read_reg(5'h2, value);
    if (value !== 8'ha5) $fatal(1, "input port C ignored external pins: %02x", value);

    // Power-on self-test publishes controller-owned handshake value 2.
    repeat (8) @(posedge clk);
    write_reg(5'h6, 8'h88);
    write_reg(5'h3, 8'h00);
    read_reg(5'h2, value);
    if (value[1:0] !== 2'b10) $fatal(1, "startup response missing: %02x", value);
    write_reg(5'h3, 8'h10);

    // Write C000 through address 80, bidirectional C, and the falling strobe.
    write_reg(5'h6, 8'h80);
    write_reg(5'h2, 8'h55);
    write_reg(5'hf, 8'hcc);
    if (pc_out !== 8'h55) $fatal(1, "DIR did not expose port-C latch");
    write_reg(5'h3, 8'h00);
    write_reg(5'h3, 8'h10);
    write_reg(5'hf, 8'hc8);
    write_reg(5'h3, 8'h00);
    read_reg(5'h2, value);
    if (value !== 8'h55) $fatal(1, "C000 mailbox round-trip failed: %02x", value);
    write_reg(5'h3, 8'h10);

    // A main-owned request in C008 is acknowledged after a bounded delay.
    write_reg(5'h6, 8'h88);
    write_reg(5'h2, 8'h01);
    write_reg(5'hf, 8'hcc);
    write_reg(5'h3, 8'h00);
    write_reg(5'h3, 8'h10);
    write_reg(5'hf, 8'hc8);
    repeat (8) @(posedge clk);
    write_reg(5'h3, 8'h00);
    read_reg(5'h2, value);
    if (value[1:0] !== 2'b10) $fatal(1, "request was not acknowledged: %02x", value);

    $display("RAD MOBILE MOTOR MAILBOX PASS");
    $finish;
end
endmodule
