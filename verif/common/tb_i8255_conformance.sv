`timescale 1ns/1ps

// Dual-model conformance for the System 32 4-player PPI boundary.
//
// jt8255 is the pinned MIT reference from D001.  It has an active-low,
// edge-observed bus, while s32_i8255 has the core's synchronous active-high
// request interface.  The tasks below apply the same logical transaction to
// both models and allow the donor's one-edge write commit before comparing
// externally visible mode-0 and BSR behavior.
module tb_i8255_conformance;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg donor_rst = 1'b1;
    reg        cs = 1'b0;
    reg        we = 1'b0;
    reg [1:0]  addr = 2'd0;
    reg [7:0]  wdata = 8'h00;
    reg [7:0]  pa = 8'h3c;
    reg [7:0]  pb = 8'ha5;
    reg [7:0]  pc_in = 8'h0f;

    wire [7:0] s32_rdata;
    wire [7:0] s32_pc_out;
    wire [7:0] jt_rdata;
    wire [7:0] jt_pc_out;
    wire [7:0] jt_pa_out;
    wire [7:0] jt_pb_out;

    s32_i8255 s32 (
        .clk(clk), .cs(cs), .we(we), .addr(addr), .wdata(wdata),
        .rdata(s32_rdata), .pa(pa), .pb(pb), .pc_in(pc_in),
        .pc_out(s32_pc_out)
    );

    jt8255 donor (
        .rst(donor_rst), .clk(clk), .addr(addr), .din(wdata),
        .dout(jt_rdata),
        .rdn(!(cs && !we)), .wrn(!(cs && we)), .csn(!cs),
        .porta_din(pa), .portb_din(pb), .portc_din(pc_in),
        .porta_dout(jt_pa_out), .portb_dout(jt_pb_out),
        .portc_dout(jt_pc_out)
    );

    integer errors = 0;
    reg [7:0] output_mask = 8'h00;

    task automatic check_pc(input [127:0] label);
        begin
            if (((s32_pc_out ^ jt_pc_out) & output_mask) !== 8'h00) begin
                $display("FAIL 8255 %0s Port-C output s32=%02x donor=%02x",
                         label, s32_pc_out, jt_pc_out);
                errors = errors + 1;
            end
        end
    endtask

    task automatic write_reg(input [1:0] a, input [7:0] d,
                             input [127:0] label);
        begin
            @(negedge clk);
            addr = a; wdata = d; cs = 1'b1; we = 1'b1;
            @(posedge clk); #1;
            @(negedge clk);
            cs = 1'b0; we = 1'b0;
            // jt8255 commits a write on the edge after its active-low pulse.
            @(posedge clk); #1;
            check_pc(label);
            if (a == 2'd3 && d[7])
                output_mask = {{4{~d[3]}}, {4{~d[0]}}};
        end
    endtask

    task automatic read_reg(input [1:0] a, input [7:0] expected,
                            input [127:0] label);
        begin
            @(negedge clk);
            addr = a; cs = 1'b1; we = 1'b0;
            @(posedge clk); #1;
            if (s32_rdata !== expected || jt_rdata !== expected) begin
                $display("FAIL 8255 %0s s32=%02x donor=%02x expected=%02x",
                         label, s32_rdata, jt_rdata, expected);
                errors = errors + 1;
            end
            if (s32_rdata !== jt_rdata) begin
                $display("FAIL 8255 %0s model mismatch s32=%02x donor=%02x",
                         label, s32_rdata, jt_rdata);
                errors = errors + 1;
            end
            @(negedge clk);
            cs = 1'b0;
        end
    endtask

    integer bit_index;
    reg [7:0] bsr_set;
    reg [7:0] bsr_reset;

    initial begin
        repeat (3) @(posedge clk);
        donor_rst = 1'b0;

        // Reset/mode-0 input contract.
        read_reg(2'd0, 8'h3c, "reset PA input");
        read_reg(2'd1, 8'ha5, "reset PB input");
        read_reg(2'd2, 8'h0f, "reset PC input");
        read_reg(2'd3, 8'h9b, "reset control");

        // Mixed mode and latch readback are shared by the two models.
        write_reg(2'd3, 8'h93, "mode 0x93");
        read_reg(2'd2, 8'h0f, "mixed PC before latch write");
        write_reg(2'd2, 8'hf0, "mixed PC latch write");
        read_reg(2'd2, 8'hff, "mixed PC latch plus pins");

        // All output mode establishes identical zeroed latches, then every
        // valid BSR bit is exercised, including the previously dropped PC7.
        write_reg(2'd3, 8'h80, "all output mode");
        read_reg(2'd3, 8'h80, "all output control");
        read_reg(2'd2, 8'h00, "all output reset PC");
        for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
            bsr_set = (bit_index << 1) | 8'h01;
            bsr_reset = (bit_index << 1);
            write_reg(2'd3, bsr_set | 8'h01, "BSR set bit");
            read_reg(2'd2, (8'h01 << bit_index), "BSR set readback");
            write_reg(2'd3, bsr_reset, "BSR reset bit");
            read_reg(2'd2, 8'h00, "BSR reset readback");
        end

        // Mode-0 output latches for A/B must remain visible through reads.
        write_reg(2'd0, 8'h12, "PA output latch");
        read_reg(2'd0, 8'h12, "PA output readback");
        write_reg(2'd1, 8'he7, "PB output latch");
        read_reg(2'd1, 8'he7, "PB output readback");

        if (errors == 0) $display("I8255 CONFORMANCE PASS");
        else             $fatal(1, "I8255 CONFORMANCE FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
