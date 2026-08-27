`timescale 1ns/1ps

// MAME i8255 direction/latch contract used by the System 32 4-player boards.
module tb_i8255;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg cs = 1'b0, we = 1'b0;
    reg [1:0] addr = 2'd0;
    reg [7:0] wdata = 8'h00;
    wire [7:0] rdata;
    reg [7:0] pa = 8'h3c, pb = 8'ha5, pc_in = 8'h0f;
    wire [7:0] pc_out;

    s32_i8255 dut (
        .clk(clk), .cs(cs), .we(we), .addr(addr), .wdata(wdata),
        .rdata(rdata), .pa(pa), .pb(pb), .pc_in(pc_in), .pc_out(pc_out)
    );

    integer errors = 0;

    task automatic write_reg(input [1:0] a, input [7:0] d);
        begin
            addr = a; wdata = d; cs = 1'b1; we = 1'b1;
            @(posedge clk); #1;
            cs = 1'b0; we = 1'b0;
        end
    endtask

    task automatic read_reg(input [1:0] a, input [7:0] expected, input [128*8-1:0] label);
        begin
            addr = a; cs = 1'b1; we = 1'b0;
            @(posedge clk); #1;
            if (rdata !== expected) begin
                $display("FAIL i8255 %0s got=%02x expected=%02x", label, rdata, expected);
                errors = errors + 1;
            end
            cs = 1'b0;
        end
    endtask

    initial begin
        // Reset mode 0: every port is input.
        read_reg(2'd0, 8'h3c, "PA input");
        read_reg(2'd1, 8'ha5, "PB input");
        read_reg(2'd2, 8'h0f, "PC all input");

        // MAME's common 0x93 setup makes PC[7:4] output and PC[3:0] input.
        // The output latch reset value is zero, so the mixed read is 0x0f.
        write_reg(2'd3, 8'h93);
        read_reg(2'd2, 8'h0f, "PC 0x93 mixed direction");
        write_reg(2'd2, 8'hf0);
        read_reg(2'd2, 8'hff, "PC output latch plus input pins");

        // BSR writes update the Port-C latch without changing the mode word.
        write_reg(2'd3, 8'h80);  // all ports output
        read_reg(2'd2, 8'h00, "PC mode-set latch reset");
        write_reg(2'd3, 8'h05);  // set PC2
        read_reg(2'd2, 8'h04, "PC BSR set");
        write_reg(2'd3, 8'h04);  // reset PC2
        read_reg(2'd2, 8'h00, "PC BSR reset");
        write_reg(2'd3, 8'h0f);  // set PC7
        read_reg(2'd2, 8'h80, "PC BSR set PC7");
        write_reg(2'd3, 8'h0e);  // reset PC7
        read_reg(2'd2, 8'h00, "PC BSR reset PC7");

        if (errors == 0) $display("I8255 MAME PASS");
        else $fatal(1, "I8255 MAME FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
