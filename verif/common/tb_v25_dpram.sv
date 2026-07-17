`timescale 1ns/1ps

// Focused V25 HLE mailbox test: block-RAM timing plus synthetic response
// overlays used by Golden Axe: The Revenge of Death Adder.
module tb_v25_dpram;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg        enable = 1'b1;
    reg        table_sel = 1'b0;
    reg        cs = 1'b0;
    reg        we = 1'b0;
    reg [11:1] addr = 11'd0;
    reg  [7:0] wdata = 8'd0;
    wire [7:0] rdata;

    s32_v25 dut (
        .clk(clk), .rst(1'b0), .enable(enable), .table_sel(table_sel),
        .prg_wr(1'b0), .prg_waddr(16'd0), .prg_wdata(8'd0),
        .cs(cs), .we(we), .addr(addr), .wdata(wdata), .rdata(rdata)
    );

    task check_byte(input [7:0] got, input [7:0] want,
                    input [255:0] what);
        begin
            if (got !== want) begin
                $display("V25 DPRAM FAIL: %0s got=%02x want=%02x",
                         what, got, want);
                $fatal(1);
            end
        end
    endtask

    initial begin
        // An ordinary mailbox address retains read-before-write behavior.
        cs = 1'b1; we = 1'b1; addr = 11'h100; wdata = 8'ha5;
        @(posedge clk); #1;
        we = 1'b0;
        @(posedge clk); #1;
        check_byte(rdata, 8'ha5, "mailbox registered read");

        // With cs low, both RAM q and the overlay selector hold their output.
        cs = 1'b0; addr = 11'h101;
        @(posedge clk); #1;
        check_byte(rdata, 8'ha5, "mailbox output hold");

        // Word index 0x89 is character offset 9 in the wakeup window:
        // 'G' for GA2 and 'A' for Arabian Fight.
        cs = 1'b1; addr = 11'h089; table_sel = 1'b0;
        @(posedge clk); #1;
        check_byte(rdata, "G", "GA2 wakeup overlay");
        table_sel = 1'b1;
        @(posedge clk); #1;
        check_byte(rdata, "A", "Arabian Fight wakeup overlay");

        // GA2's sprite-expansion response table remains in the low window.
        table_sel = 1'b0; addr = 11'h000;
        @(posedge clk); #1;
        check_byte(rdata, 8'h0a, "GA2 protection overlay");

        // Disabling the HLE also holds the most recent synchronous result.
        enable = 1'b0; addr = 11'h100;
        @(posedge clk); #1;
        check_byte(rdata, 8'h0a, "disabled HLE output hold");

        $display("V25 DPRAM PASS");
        $finish;
    end
endmodule
