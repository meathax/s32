`timescale 1ns/1ps
`default_nettype none

// Minimal s80x86 bus source for testing the production V25 wrapper without
// pulling the complete CPU into this focused memory/protocol regression.
module Core (
    input  wire         clk,
    input  wire         ce,
    input  wire         reset,
    input  wire         nmi,
    input  wire         intr,
    input  wire [7:0]   irq,
    output logic        inta,
    output logic [19:1] instr_m_addr,
    input  wire [15:0]  instr_m_data_in,
    output logic        instr_m_access,
    input  wire         instr_m_ack,
    output logic [7:0]  opcode_xlat_in,
    input  wire [7:0]   opcode_xlat_out,
    input  wire         opcode_xlat_en,
    output logic [19:1] data_m_addr,
    input  wire [15:0]  data_m_data_in,
    output logic [15:0] data_m_data_out,
    output logic        data_m_access,
    input  wire         data_m_ack,
    output logic        data_m_wr_en,
    output logic [1:0]  data_m_bytesel,
    output logic        d_io,
    output logic        lock,
    output logic        debug_stopped,
    input  wire         debug_seize,
    input  wire [7:0]   debug_addr,
    input  wire         debug_run,
    output logic [15:0] debug_val,
    input  wire [15:0]  debug_wr_val,
    input  wire         debug_wr_en
);
initial begin
    inta = 0; instr_m_addr = 0; instr_m_access = 0; opcode_xlat_in = 0;
    data_m_addr = 0; data_m_data_out = 0; data_m_access = 0;
    data_m_wr_en = 0; data_m_bytesel = 0; d_io = 0; lock = 0;
    debug_stopped = 0; debug_val = 0;
end
endmodule

module tb_v25_internal_data;
reg clk = 0;
reg clk_v25 = 0;
reg rst = 1;
reg enable = 1;
reg pause = 0;
wire rom_req;
wire [15:3] rom_addr;

always #5 clk = ~clk;
always #10 clk_v25 = ~clk_v25;

s32_v25_cpu dut (
    .clk(clk), .clk_v25(clk_v25), .rst(rst), .enable(enable), .pause(pause),
    .table_sel(1'b0), .prg_wr(1'b0), .prg_waddr(16'd0), .prg_wdata(8'd0),
    .rom_req(rom_req), .rom_addr(rom_addr), .rom_data(64'd0), .rom_ack(1'b0),
    .cs(1'b0), .we(1'b0), .addr(11'd0), .wdata(8'd0), .rdata()
);

task automatic drive_access(
    input [19:0] byte_addr,
    input [15:0] value,
    input [1:0] lanes,
    input write_access
);
begin
    @(negedge clk_v25);
    dut.cpu.data_m_addr = byte_addr[19:1];
    dut.cpu.data_m_data_out = value;
    dut.cpu.data_m_bytesel = lanes;
    dut.cpu.data_m_wr_en = write_access;
    dut.cpu.data_m_access = 1'b1;
end
endtask

task automatic finish_access;
begin
    @(negedge clk_v25);
    dut.cpu.data_m_access = 1'b0;
    dut.cpu.data_m_wr_en = 1'b0;
    dut.cpu.data_m_bytesel = 2'b00;
end
endtask

task automatic wait_ce;
begin
    do @(posedge clk_v25); while (!dut.v25_ce);
    #1;
end
endtask

task automatic write_word(
    input [19:0] byte_addr,
    input [15:0] value,
    input [1:0] lanes
);
begin
    drive_access(byte_addr, value, lanes, 1'b1);
    wait_ce();
    if (!dut.data_ack || dut.bus_state != 4'd0) begin
        $display("V25 INTERNAL DATA FAIL: write did not ack in BUS_IDLE");
        $fatal(1);
    end
    finish_access();
    wait_ce();
end
endtask

task automatic read_word(
    input [19:0] byte_addr,
    output [15:0] value
);
begin
    drive_access(byte_addr, 16'd0, 2'b11, 1'b0);
    wait_ce();
    if (dut.data_ack || dut.bus_state != 4'd7) begin
        $display("V25 INTERNAL DATA FAIL: read did not enter one BUS_D_INT_WAIT");
        $fatal(1);
    end
    wait_ce();
    if (!dut.data_ack || dut.bus_state != 4'd0) begin
        $display("V25 INTERNAL DATA FAIL: read did not ack after one wait state");
        $fatal(1);
    end
    value = dut.data_rdata;
    finish_access();
    wait_ce();
end
endtask

reg [15:0] observed;
reg [13:0] paused_accum;
initial begin
    repeat (4) @(posedge clk_v25);
    rst = 0;
    wait (dut.rst_v25 == 0 && dut.enable_v25 == 1);

    // Pause crosses from clk_sys into clk_v25 through the production two-flop
    // level synchronizer. Once accepted, both the virtual clock pulse and its
    // fractional phase must stay frozen, then resume without a reset.
    wait_ce();
    pause = 1'b1;
    wait (dut.pause_v25 == 1'b1);
    @(negedge clk_v25);
    paused_accum = dut.v25_ce_accum;
    repeat (8) begin
        @(negedge clk_v25);
        if (dut.v25_ce || dut.v25_ce_accum !== paused_accum) begin
            $display("V25 INTERNAL DATA FAIL: pause did not freeze cadence");
            $fatal(1);
        end
    end
    pause = 1'b0;
    wait (dut.pause_v25 == 1'b0);
    wait_ce();

    // Independent low/high writes must preserve the other byte.
    write_word(20'hffe20, 16'h0012, 2'b01);
    write_word(20'hffe20, 16'h3400, 2'b10);
    read_word(20'hffe20, observed);
    if (observed !== 16'h3412) begin
        $display("V25 INTERNAL DATA FAIL: IRAM byte enables got %04x", observed);
        $fatal(1);
    end

    // The SFR page shares physical storage but must remain address-separated.
    write_word(20'hfff20, 16'ha55a, 2'b11);
    read_word(20'hfff20, observed);
    if (observed !== 16'ha55a) begin
        $display("V25 INTERNAL DATA FAIL: SFR read-back got %04x", observed);
        $fatal(1);
    end
    read_word(20'hffe20, observed);
    if (observed !== 16'h3412) begin
        $display("V25 INTERNAL DATA FAIL: SFR write aliased IRAM, got %04x", observed);
        $fatal(1);
    end

    // PRC high byte remains architectural; its paired even SFR byte is memory.
    write_word(20'hfffea, 16'h005c, 2'b01);
    write_word(20'hfffea, 16'h4f00, 2'b10);
    read_word(20'hfffea, observed);
    if (observed !== 16'h4f5c || dut.v25_prc !== 8'h4f) begin
        $display("V25 INTERNAL DATA FAIL: PRC semantics got %04x PRC=%02x",
                 observed, dut.v25_prc);
        $fatal(1);
    end

    // IDB write moves the internal window; read it back at the new base, then
    // restore FF so the firmware-facing reset map is unchanged.
    write_word(20'hffffe, 16'hfe00, 2'b10);
    if (dut.v25_idb !== 8'hfe) begin
        $display("V25 INTERNAL DATA FAIL: IDB write did not take effect");
        $fatal(1);
    end
    read_word(20'hfeffe, observed);
    if (observed[15:8] !== 8'hfe) begin
        $display("V25 INTERNAL DATA FAIL: moved IDB read got %04x", observed);
        $fatal(1);
    end
    write_word(20'hfeffe, 16'hff00, 2'b10);
    if (dut.v25_idb !== 8'hff) begin
        $display("V25 INTERNAL DATA FAIL: IDB restore did not take effect");
        $fatal(1);
    end

    // Reset changes PRC/IDB only. Internal RAM must retain its contents.
    rst = 1;
    repeat (3) @(posedge clk_v25);
    rst = 0;
    wait (dut.rst_v25 == 0 && dut.enable_v25 == 1);
    if (dut.v25_prc !== 8'h4e || dut.v25_idb !== 8'hff) begin
        $display("V25 INTERNAL DATA FAIL: special-register reset mismatch");
        $fatal(1);
    end
    read_word(20'hffe20, observed);
    if (observed !== 16'h3412) begin
        $display("V25 INTERNAL DATA FAIL: reset cleared IRAM, got %04x", observed);
        $fatal(1);
    end

    $display("V25 INTERNAL DATA PASS");
    $finish;
end

endmodule

`default_nettype wire
