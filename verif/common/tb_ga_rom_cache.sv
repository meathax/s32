`timescale 1ns/1ps

// Directed/reference-model verification for the Golden Axe-only synchronous
// main-ROM cache. This test intentionally instantiates only the cache so it can
// run without Quartus, Qsys, vendor memories, or an RBF build.
module tb_ga_rom_cache;

reg clk = 1'b0;
always #5 clk = ~clk;

reg         rst = 1'b1;
reg         invalidate = 1'b0;
reg         if_req = 1'b0;
reg  [20:3] if_line_addr = 18'd0;
reg   [2:0] if_offset = 3'd0;
wire [63:0] if_data;
wire        if_ack;
reg         data_req = 1'b0;
reg  [20:0] data_addr = 21'd0;
wire [15:0] data_data;
wire        data_ack;
wire        rom_req;
wire [23:1] rom_addr;
reg  [15:0] rom_data = 16'd0;
reg         rom_ack = 1'b0;

integer errors = 0;
integer rom_request_count = 0;
integer response_delay = 1;
integer pending_delay = 0;
reg     rom_pending = 1'b0;
reg [22:0] pending_addr = 23'd0;
reg [22:0] request_log [0:255];

s32_ga_rom_cache dut (
    .clk(clk),
    .rst(rst),
    .invalidate(invalidate),
    .if_req(if_req),
    .if_line_addr(if_line_addr),
    .if_offset(if_offset),
    .if_data(if_data),
    .if_ack(if_ack),
    .data_req(data_req),
    .data_addr(data_addr),
    .data_data(data_data),
    .data_ack(data_ack),
    .rom_req(rom_req),
    .rom_addr(rom_addr),
    .rom_data(rom_data),
    .rom_ack(rom_ack)
);

function automatic [15:0] reference_word(input [22:0] word_addr);
begin
    reference_word = {word_addr[7:0] ^ 8'ha5,
                      word_addr[15:8] ^ word_addr[22:15] ^ 8'h3c};
end
endfunction

function automatic [63:0] reference_line(input [17:0] line_addr);
reg [22:0] base;
begin
    base = {3'b000, line_addr, 2'b00};
    reference_line = {reference_word(base + 23'd3),
                      reference_word(base + 23'd2),
                      reference_word(base + 23'd1),
                      reference_word(base)};
end
endfunction

task automatic fail(input string message);
begin
    $display("ERROR @ %0t: %s", $time, message);
    errors = errors + 1;
end
endtask

task automatic check_request_sequence(
    input integer first,
    input [17:0] line_addr
);
integer i;
reg [22:0] base;
begin
    base = {3'b000, line_addr, 2'b00};
    for (i = 0; i < 4; i = i + 1)
        if (request_log[first+i] !== base + i)
            fail($sformatf("ROM request %0d was %06x, expected %06x",
                           first+i, request_log[first+i], base+i));
end
endtask

task automatic fetch_line(
    input [17:0] line_addr,
    input  [2:0] offset,
    input integer expected_rom_requests
);
integer req_start;
integer timeout;
reg [63:0] expected;
begin
    req_start = rom_request_count;
    expected = reference_line(line_addr) >> (offset * 8);
    @(negedge clk);
    if_line_addr = line_addr;
    if_offset = offset;
    if_req = 1'b1;
    timeout = 0;
    while (!if_ack && timeout < 80) begin
        @(negedge clk);
        timeout = timeout + 1;
    end
    if (!if_ack)
        fail("instruction lookup timed out");
    else if (if_data !== expected)
        fail($sformatf("instruction data %016x, expected %016x", if_data, expected));
    if ((rom_request_count - req_start) != expected_rom_requests)
        fail($sformatf("instruction lookup made %0d ROM requests, expected %0d",
                       rom_request_count-req_start, expected_rom_requests));
    if (expected_rom_requests == 4)
        check_request_sequence(req_start, line_addr);

    repeat (3) begin
        @(negedge clk);
        if (!if_ack)
            fail("instruction acknowledge was not held while request remained asserted");
    end
    if_req = 1'b0;
    @(negedge clk);
    if (if_ack)
        fail("instruction acknowledge did not clear after request dropped");
end
endtask

task automatic read_data(
    input [17:0] line_addr,
    input  [1:0] word_sel,
    input integer expected_rom_requests
);
integer req_start;
integer timeout;
reg [63:0] expected_line;
reg [15:0] expected_word;
begin
    req_start = rom_request_count;
    expected_line = reference_line(line_addr);
    case (word_sel)
        2'd0: expected_word = expected_line[15:0];
        2'd1: expected_word = expected_line[31:16];
        2'd2: expected_word = expected_line[47:32];
        default: expected_word = expected_line[63:48];
    endcase
    @(negedge clk);
    data_addr = {line_addr, 3'b000} | {17'd0, word_sel, 1'b0};
    data_req = 1'b1;
    timeout = 0;
    while (!data_ack && timeout < 80) begin
        @(negedge clk);
        timeout = timeout + 1;
    end
    if (!data_ack)
        fail("data lookup timed out");
    else if (data_data !== expected_word)
        fail($sformatf("data word %04x, expected %04x", data_data, expected_word));
    if ((rom_request_count - req_start) != expected_rom_requests)
        fail($sformatf("data lookup made %0d ROM requests, expected %0d",
                       rom_request_count-req_start, expected_rom_requests));
    if (expected_rom_requests == 4)
        check_request_sequence(req_start, line_addr);

    repeat (2) begin
        @(negedge clk);
        if (!data_ack)
            fail("data acknowledge was not held while request remained asserted");
    end
    data_req = 1'b0;
    @(negedge clk);
    if (data_ack)
        fail("data acknowledge did not clear after request dropped");
end
endtask

// Small deterministic SDRAM oracle. Requests are logged independently of the
// DUT, and every returned value is generated directly from its word address.
always @(negedge clk) begin
    rom_ack = 1'b0;
    if (rom_pending) begin
        if (pending_delay == 0) begin
            rom_data = reference_word(pending_addr);
            rom_ack = 1'b1;
            rom_pending = 1'b0;
        end
        else begin
            pending_delay = pending_delay - 1;
        end
    end
    if (rom_req) begin
        if (rom_pending)
            fail("DUT issued a second ROM request req_start the prior response");
        pending_addr = rom_addr;
        pending_delay = response_delay;
        rom_pending = 1'b1;
        request_log[rom_request_count] = rom_addr;
        rom_request_count = rom_request_count + 1;
    end
end

initial begin : run_tests
    reg [17:0] line_a;
    reg [17:0] line_b;
    reg [17:0] line_c;
    reg [17:0] line_d;
    reg [17:0] line_e;
    integer req_start;
    integer timeout;
    reg [22:0] base;

    line_a = 18'h01234;
    line_b = line_a ^ 18'h00020; // same direct-map index, different tag
    line_c = 18'h05549;
    line_d = 18'h0a61e;
    line_e = 18'h1b203;

    repeat (4) @(negedge clk);
    rst = 1'b0;

    // Cold instruction fill, byte-offset alignment, and held acknowledge.
    fetch_line(line_a, 3'd0, 4);
    fetch_line(line_a, 3'd3, 0);

    // The single shared lookup port also serves V60 data reads from the line.
    read_data(line_a, 2'd2, 0);

    // Direct-map aliasing must miss, replace, and then miss again on the old tag.
    fetch_line(line_b, 3'd1, 4);
    fetch_line(line_a, 3'd0, 4);

    // Cache a data line at another index, then launch simultaneous requests.
    fetch_line(line_c, 3'd0, 4);
    req_start = rom_request_count;
    @(negedge clk);
    if_line_addr = line_d;
    if_offset = 3'd2;
    data_addr = {line_c, 3'b000} | 21'd6;
    if_req = 1'b1;
    data_req = 1'b1;
    timeout = 0;
    while ((!if_ack || !data_ack) && timeout < 100) begin
        @(negedge clk);
        timeout = timeout + 1;
    end
    if (!if_ack || !data_ack)
        fail("simultaneous instruction/data arbitration timed out");
    if (if_data !== (reference_line(line_d) >> 16))
        fail("instruction-priority result did not match reference line");
    if (data_data !== reference_line(line_c)[63:48])
        fail("queued data result did not match cached reference word");
    if ((rom_request_count-req_start) != 4)
        fail("simultaneous request did not give the instruction miss sole ROM priority");
    else
        check_request_sequence(req_start, line_d);
    if_req = 1'b0;
    data_req = 1'b0;
    @(negedge clk);

    // Explicit invalidation makes an otherwise cached line miss again.
    @(negedge clk);
    invalidate = 1'b1;
    @(negedge clk);
    invalidate = 1'b0;
    fetch_line(line_c, 3'd0, 4);

    // Invalidation while a response is outstanding drains that response,
    // abandons the partial line, then retries the held request from word zero.
    response_delay = 3;
    req_start = rom_request_count;
    @(negedge clk);
    if_line_addr = line_e;
    if_offset = 3'd0;
    if_req = 1'b1;
    timeout = 0;
    while ((rom_request_count == req_start) && timeout < 20) begin
        @(negedge clk);
        timeout = timeout + 1;
    end
    @(negedge clk);
    invalidate = 1'b1;
    @(negedge clk);
    invalidate = 1'b0;
    timeout = 0;
    while (!if_ack && timeout < 140) begin
        @(negedge clk);
        timeout = timeout + 1;
    end
    if (!if_ack)
        fail("invalidated in-flight fill did not retry to completion");
    if (if_data !== reference_line(line_e))
        fail("retried fill returned data different from the reference model");
    if ((rom_request_count-req_start) != 5)
        fail($sformatf("invalidated fill made %0d requests, expected drained word plus four-word retry",
                       rom_request_count-req_start));
    base = {3'b000, line_e, 2'b00};
    if (request_log[req_start] !== base || request_log[req_start+1] !== base)
        fail("invalidated fill did not restart at word zero");
    check_request_sequence(req_start+1, line_e);
    if_req = 1'b0;
    @(negedge clk);

    if (errors == 0)
        $display("PASS: Golden Axe ROM cache directed/reference tests passed (%0d ROM requests)",
                 rom_request_count);
    else
        $display("FAIL: Golden Axe ROM cache test recorded %0d errors", errors);
    $finish;
end

endmodule
