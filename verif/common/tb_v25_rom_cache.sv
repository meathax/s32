`timescale 1ns/1ps
`default_nettype none

module tb_v25_rom_cache;

reg clk = 1'b0;
always #5 clk = ~clk;

reg rst = 1'b1;
reg invalidate = 1'b0;
reg cpu_req = 1'b0;
reg [15:1] cpu_addr = 15'd0;
wire [15:0] cpu_data;
wire cpu_ack;
wire rom_req;
wire [15:3] rom_addr;
reg [63:0] rom_data = 64'd0;
reg rom_ack = 1'b0;

s32_v25_rom_cache dut (
    .clk(clk), .rst(rst), .invalidate(invalidate),
    .cpu_req(cpu_req), .cpu_addr(cpu_addr),
    .cpu_data(cpu_data), .cpu_ack(cpu_ack),
    .rom_req(rom_req), .rom_addr(rom_addr),
    .rom_data(rom_data), .rom_ack(rom_ack)
);

integer rom_requests = 0;
integer timeout;
reg service_pending = 1'b0;
reg [2:0] service_delay = 3'd0;
reg [15:3] service_addr = 13'd0;
reg [15:3] last_request_addr = 13'd0;

function automatic [15:0] word_for(input [15:1] addr);
begin
    word_for = 16'h4000 ^ {1'b0, addr};
end
endfunction

function automatic [63:0] line_for(input [15:3] addr);
reg [15:1] base;
begin
    base = {addr, 2'b00};
    line_for = {
        word_for(base + 3), word_for(base + 2),
        word_for(base + 1), word_for(base)
    };
end
endfunction

// Delayed external service models a p5 mailbox/burst response. Requests are
// pulses and the live address is deliberately not consulted after capture.
always @(posedge clk) begin
    rom_ack <= 1'b0;
    if (rst) begin
        service_pending <= 1'b0;
        service_delay <= 3'd0;
    end else begin
        if (rom_req) begin
            if (service_pending)
                $fatal(1, "cache issued a second miss while one was pending");
            service_pending <= 1'b1;
            service_delay <= 3'd3;
            service_addr <= rom_addr;
            last_request_addr <= rom_addr;
            rom_requests <= rom_requests + 1;
        end
        if (service_pending) begin
            if (service_delay == 0) begin
                rom_data <= line_for(service_addr);
                rom_ack <= 1'b1;
                service_pending <= 1'b0;
            end else begin
                service_delay <= service_delay - 1'd1;
            end
        end
    end
end

task automatic access_word(
    input [15:1] addr,
    input integer expected_misses
);
integer reads_before;
begin
    reads_before = rom_requests;
    @(negedge clk);
    cpu_addr = addr;
    cpu_req = 1'b1;
    @(negedge clk);
    cpu_req = 1'b0;
    // Move the live bus after request capture to catch missing address latches.
    cpu_addr = ~addr;

    timeout = 0;
    while (!cpu_ack && timeout < 40) begin
        @(posedge clk); #1;
        timeout = timeout + 1;
    end
    if (!cpu_ack)
        $fatal(1, "cache access timed out at word address %h", addr);
    if (cpu_data !== word_for(addr))
        $fatal(1, "cache data mismatch at %h: got %h expected %h",
               addr, cpu_data, word_for(addr));
    if (rom_requests !== reads_before + expected_misses)
        $fatal(1, "cache miss count mismatch at %h: got %0d expected delta %0d",
               addr, rom_requests - reads_before, expected_misses);
    if (expected_misses != 0 && last_request_addr !== addr[15:3])
        $fatal(1, "cache line address mismatch: got %h expected %h",
               last_request_addr, addr[15:3]);
    while (cpu_ack) begin @(posedge clk); #1; end
end
endtask

reg [15:1] line_a0;
reg [15:1] line_a3;
reg [15:1] conflict_a2;
reg [15:1] cancelled_a1;
reg [15:1] retry_a2;
initial begin
    line_a0      = {8'h12, 5'h05, 2'd0};
    line_a3      = {8'h12, 5'h05, 2'd3};
    conflict_a2  = {8'h34, 5'h05, 2'd2};
    cancelled_a1 = {8'h56, 5'h0d, 2'd1};
    retry_a2     = {8'h78, 5'h0e, 2'd2};

    repeat (4) @(posedge clk);
    @(negedge clk); rst = 1'b0;

    // Cold miss, then a different word in the same 8-byte line must hit.
    access_word(line_a0, 1);
    access_word(line_a3, 0);

    // Same index/different tag replaces the direct-mapped line. Returning to
    // the original tag must miss again rather than return aliased data.
    access_word(conflict_a2, 1);
    access_word(line_a0, 1);

    // A loader write invalidates all lines.
    @(negedge clk); invalidate = 1'b1;
    @(negedge clk); invalidate = 1'b0;
    access_word(line_a3, 1);

    // Invalidation during a delayed fill discards its stale response. The next
    // retry must issue a fresh miss and complete with the correct word.
    @(negedge clk); cpu_addr = cancelled_a1; cpu_req = 1'b1;
    @(negedge clk); cpu_req = 1'b0;
    timeout = 0;
    while (!rom_req && timeout < 10) begin
        @(posedge clk); #1; timeout = timeout + 1;
    end
    if (!rom_req) $fatal(1, "cancelled-fill request was never issued");
    @(negedge clk); invalidate = 1'b1;
    @(negedge clk); invalidate = 1'b0;
    repeat (8) begin
        @(posedge clk); #1;
        if (cpu_ack) $fatal(1, "stale fill acknowledged after invalidation");
    end
    access_word(cancelled_a1, 1);

    // Reset is also a complete cache invalidation.
    @(negedge clk); rst = 1'b1;
    repeat (2) @(posedge clk);
    @(negedge clk); rst = 1'b0;
    access_word(cancelled_a1, 1);

    $display("V25 ROM CACHE PASS");
    $finish;
end

endmodule

`default_nettype wire
