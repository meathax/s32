// Directed handshake test for the DBZ V.R. V.S. protection copy.
module tb_dbz_prot;

logic clk = 1'b0;
logic rst = 1'b1;
logic enable = 1'b1;
logic cpu_write = 1'b0;
logic        wram_req;
logic        wram_we;
logic [15:0] wram_addr;
logic [15:0] wram_wdata;
logic [1:0]  wram_be;
logic [15:0] wram_rdata = 16'h0000;
logic        wram_ack = 1'b0;
logic [15:0] memory [0:16'hffff];
integer read_count = 0;
integer write_count = 0;

always #5 clk = ~clk;

s32_prot_dbzvrvs dut (
    .clk(clk), .rst(rst), .enable(enable), .cpu_write(cpu_write),
    .wram_req(wram_req), .wram_we(wram_we), .wram_addr(wram_addr),
    .wram_wdata(wram_wdata), .wram_be(wram_be),
    .wram_rdata(wram_rdata), .wram_ack(wram_ack)
);

always @(posedge clk) begin
    wram_ack <= wram_req;
    if (wram_req && !wram_we) begin
        if (wram_addr != 16'h0022)
            $fatal(1, "DBZ read address %04x, expected 0022", wram_addr);
        wram_rdata <= memory[wram_addr];
        read_count <= read_count + 1;
    end
    if (wram_req && wram_we) begin
        if (wram_addr != 16'h4064)
            $fatal(1, "DBZ write address %04x, expected 4064", wram_addr);
        if (wram_be != 2'b11)
            $fatal(1, "DBZ write byte enables %b, expected 11", wram_be);
        memory[wram_addr] <= wram_wdata;
        write_count <= write_count + 1;
    end
end

initial begin
    memory[16'h0022] = 16'h5a3c;
    memory[16'h4064] = 16'h0000;
    repeat (3) @(negedge clk);
    rst <= 1'b0;

    @(negedge clk);
    cpu_write <= 1'b1;
    @(negedge clk);
    cpu_write <= 1'b0;

    wait (write_count == 1);
    @(negedge clk);
    // The shared core returns a level acknowledgement for a held request;
    // the read address is present on the request and acknowledgement edges.
    if (read_count != 2)
        $fatal(1, "DBZ read count %0d, expected 2 held-request edges", read_count);
    if (memory[16'h4064] != 16'h5a3c)
        $fatal(1, "DBZ copied %04x, expected 5a3c", memory[16'h4064]);
    if (dut.wram_req)
        $fatal(1, "DBZ request remained asserted after write acknowledgement");

    $display("DBZ protection handshake PASS: %04x -> %04x",
             memory[16'h0022], memory[16'h4064]);
    $finish;
end

endmodule
