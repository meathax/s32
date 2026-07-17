// Directed palette test: registered reads, format aliasing, byte enables,
// mixer read port, and the serialized write-both partner copy.
`timescale 1ns/1ps

module tb_palette;

reg clk = 0;
always #5 clk = ~clk;

reg         cpu_we = 0;
reg  [14:0] cpu_addr = 0;
reg  [15:0] cpu_wdata = 0;
reg   [1:0] cpu_be = 0;
wire [15:0] cpu_rdata;
reg  [15:0] mixer_r4e = 0;
reg  [13:0] mix_addr = 0;
wire [15:0] mix_data;

s32_palette dut (
    .clk(clk),
    .cpu_we(cpu_we), .cpu_addr(cpu_addr), .cpu_wdata(cpu_wdata),
    .cpu_be(cpu_be), .cpu_rdata(cpu_rdata), .mixer_r4e(mixer_r4e),
    .mix_addr(mix_addr), .mix_data(mix_data)
);

function automatic [15:0] to_alt(input [15:0] v);
    to_alt = {v[15], v[14], v[9], v[4], v[13:10], v[8:5], v[3:0]};
endfunction

function automatic [15:0] from_alt(input [15:0] v);
    from_alt = {v[15], v[14], v[11:8], v[13], v[7:4], v[12], v[3:0]};
endfunction

integer errors = 0;

task check16(input [15:0] got, input [15:0] want, input [255:0] what);
    if (got !== want) begin
        errors = errors + 1;
        $display("  FAIL %0s: got=%04x want=%04x", what, got, want);
    end
endtask

task write_word(
    input [14:0] addr,
    input [15:0] data,
    input  [1:0] be,
    input        both
);
    @(negedge clk);
    cpu_addr = addr;
    cpu_wdata = data;
    cpu_be = be;
    mixer_r4e = both ? 16'h0080 : 16'h0000;
    cpu_we = 1'b1;
    @(posedge clk); #1;
    @(negedge clk);
    cpu_we = 1'b0;
    mixer_r4e = 16'h0000;
    // Commits a pending mirror, or supplies the normal idle/read edge.
    @(posedge clk); #1;
endtask

task expect_cpu(input [14:0] addr, input [15:0] want, input [255:0] what);
    @(negedge clk);
    cpu_addr = addr;
    cpu_we = 1'b0;
    @(posedge clk); #1;
    check16(cpu_rdata, want, what);
endtask

task expect_mix(input [13:0] addr, input [15:0] want, input [255:0] what);
    @(negedge clk);
    mix_addr = addr;
    @(posedge clk); #1;
    check16(mix_data, want, what);
endtask

reg [15:0] expected;
reg [15:0] old_alt;

initial begin
    repeat (2) @(posedge clk);

    // Native full-word and byte-lane writes.
    write_word(15'h0012, 16'hABCD, 2'b11, 1'b0);
    expect_cpu(15'h0012, 16'hABCD, "native full write/read");
    write_word(15'h0012, 16'h00EF, 2'b01, 1'b0);
    expect_cpu(15'h0012, 16'hABEF, "native low-byte write");
    write_word(15'h0012, 16'h1200, 2'b10, 1'b0);
    expect_cpu(15'h0012, 16'h12EF, "native high-byte write");
    expect_mix(14'h0012, 16'h12EF, "independent mixer read");

    // Converted view: a full write followed by both byte lanes.  Expected
    // values are formed in alias space and then permuted back to storage.
    write_word(15'h4044, 16'hD39A, 2'b11, 1'b0);
    expect_cpu(15'h4044, 16'hD39A, "converted full write/read");
    expect_cpu(15'h0044, from_alt(16'hD39A), "converted native storage");

    old_alt = 16'hD39A;
    expected = from_alt({old_alt[15:8], 8'hE7});
    write_word(15'h4044, 16'h00E7, 2'b01, 1'b0);
    expect_cpu(15'h0044, expected, "converted low-byte mask permutation");
    old_alt = {old_alt[15:8], 8'hE7};
    expected = from_alt({8'h26, old_alt[7:0]});
    write_word(15'h4044, 16'h2600, 2'b10, 1'b0);
    expect_cpu(15'h0044, expected, "converted high-byte mask permutation");
    expect_cpu(15'h4044, 16'h26E7, "converted byte-merged readback");

    // Seed unequal pair words.  A partial write-both must copy untouched
    // bits from the SOURCE (ABCD), yielding ABEF in both banks rather than
    // preserving the partner's high byte (13EF).
    write_word(15'h0033, 16'hABCD, 2'b11, 1'b0);
    write_word(15'h2033, 16'h1357, 2'b11, 1'b0);
    @(negedge clk);
    mix_addr = 14'h2033;
    cpu_addr = 15'h0033;
    cpu_wdata = 16'h00EF;
    cpu_be = 2'b01;
    mixer_r4e = 16'h0080;
    cpu_we = 1'b1;
    @(posedge clk); #1;
    check16(mix_data, 16'h1357, "write-both source edge leaves partner old");
    @(negedge clk);
    cpu_we = 1'b0;
    mixer_r4e = 16'h0000;
    @(posedge clk); #1;
    check16(cpu_rdata, 16'hABEF, "write-both source merged word");
    check16(mix_data, 16'h1357, "pending edge has read-before-write data");
    @(posedge clk); #1;
    check16(mix_data, 16'hABEF, "pending partner copy committed");
    expect_cpu(15'h2033, 16'hABEF, "write-both partner equals merged source");

    // Reverse direction and converted-view partial write-both.
    write_word(15'h2055, 16'h2468, 2'b11, 1'b0);
    write_word(15'h0055, 16'hDEAD, 2'b11, 1'b0);
    write_word(15'h2055, 16'hB100, 2'b10, 1'b1);
    expect_cpu(15'h2055, 16'hB168, "reverse write-both source");
    expect_cpu(15'h0055, 16'hB168, "reverse write-both partner");

    write_word(15'h0066, 16'h5A3C, 2'b11, 1'b0);
    write_word(15'h2066, 16'h0F0F, 2'b11, 1'b0);
    old_alt = to_alt(16'h5A3C);
    expected = from_alt({old_alt[15:8], 8'h91});
    write_word(15'h4066, 16'h0091, 2'b01, 1'b1);
    expect_cpu(15'h4066, {old_alt[15:8], 8'h91},
               "converted write-both alias readback");
    expect_cpu(15'h2066, expected,
               "converted write-both partner native data");

    if (errors == 0)
        $display("PALETTE PASS");
    else begin
        $display("PALETTE FAIL: %0d errors", errors);
        $fatal(1);
    end
    $finish;
end

endmodule
