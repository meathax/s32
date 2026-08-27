// Focused headless protocol check for the GunCon-only SNAC adapter.
// The reduced timing parameters keep this test fast; the production instance
// uses the clk_sys-scaled values in rtl/io/s32_guncon_snac.sv.
module tb_guncon_snac;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst = 1'b1;
    reg enable_p1 = 1'b0;
    reg enable_p2 = 1'b0;
    reg frame_sync = 1'b0;
    reg data_in = 1'b1;
    reg ack_in = 1'b1;

    wire select1_n, select2_n, command, serial_clk;
    wire p1_connected, p2_connected, p1_sample_valid, p2_sample_valid;
    wire [7:0] p1_device_id, p2_device_id;
    wire [15:0] p1_buttons, p2_buttons;
    wire [8:0] p1_raw_x, p1_raw_y, p2_raw_x, p2_raw_y;
    wire p1_gun_aim_valid, p2_gun_aim_valid;
    wire [9:0] p1_gun_x, p2_gun_x;
    wire [7:0] p1_gun_y, p2_gun_y;

    s32_guncon_snac #(
        .HALF_PERIOD(4), .SELECT_DELAY(2), .ACK_TIMEOUT(8),
        .INTERBYTE_DELAY(2), .DESELECT_DELAY(2)
    ) dut (
        .clk(clk), .rst(rst), .enable_p1(enable_p1), .enable_p2(enable_p2),
        .frame_sync(frame_sync), .data_in(data_in), .ack_in(ack_in),
        .select1_n(select1_n), .select2_n(select2_n),
        .command(command), .serial_clk(serial_clk),
        .p1_connected(p1_connected), .p2_connected(p2_connected),
        .p1_sample_valid(p1_sample_valid), .p2_sample_valid(p2_sample_valid),
        .p1_device_id(p1_device_id), .p2_device_id(p2_device_id),
        .p1_buttons(p1_buttons), .p2_buttons(p2_buttons),
        .p1_raw_x(p1_raw_x), .p1_raw_y(p1_raw_y),
        .p2_raw_x(p2_raw_x), .p2_raw_y(p2_raw_y),
        .p1_gun_aim_valid(p1_gun_aim_valid),
        .p2_gun_aim_valid(p2_gun_aim_valid),
        .p1_gun_x(p1_gun_x), .p2_gun_x(p2_gun_x),
        .p1_gun_y(p1_gun_y), .p2_gun_y(p2_gun_y)
    );

    // 0xff, GunCon ID 0x63, 0x5a, buttons, x low/high, y low/high.
    reg [7:0] response [0:8];
    integer bit_no;
    integer byte_no;
    integer cycles;
    wire selected = !select1_n || !select2_n;
    initial begin
        response[0] = 8'hff;
        response[1] = 8'h63;
        response[2] = 8'h5a;
        response[3] = 8'hff; // decoded active buttons include trigger/cross
        response[4] = 8'h9f; // ~{9f,ff} = buttons[14:13] pressed
        response[5] = 8'h0d; // raw X = 0x10d -> normalized X = 511
        response[6] = 8'h01;
        response[7] = 8'h80; // raw Y = 0x080 -> normalized Y = 117
        response[8] = 8'h00;
        bit_no = 0;
        byte_no = 0;
        cycles = 0;
        repeat (4) @(posedge clk);
        rst <= 1'b0;
        enable_p1 <= 1'b1;
        repeat (4) @(posedge clk);
        frame_sync <= 1'b1;
        @(posedge clk);
        frame_sync <= 1'b0;
        for (cycles = 0; cycles < 5000 && !p1_sample_valid; cycles = cycles + 1)
            @(posedge clk);
        if (!p1_sample_valid)
            $fatal(1, "GunCon sample timeout");
        if (!p1_connected || !p1_gun_aim_valid || p1_device_id != 8'h63)
            $fatal(1, "GunCon identification failed id=%h connected=%b valid=%b",
                   p1_device_id, p1_connected, p1_gun_aim_valid);
        if (p1_buttons != 16'h6000)
            $fatal(1, "GunCon buttons mismatch: %h", p1_buttons);
        if (p1_raw_x != 9'h10d || p1_raw_y != 9'h080)
            $fatal(1, "GunCon raw coordinates mismatch: %h %h", p1_raw_x, p1_raw_y);
        if (p1_gun_x != 10'd511 || p1_gun_y != 8'd117)
            $fatal(1, "GunCon normalized coordinates mismatch: %d %d",
                   p1_gun_x, p1_gun_y);

        // Re-use the same packet model on the second SNAC select to prove the
        // two-port sequencing path rather than only the P1 wiring.
        enable_p1 <= 1'b0;
        enable_p2 <= 1'b1;
        repeat (4) @(posedge clk);
        frame_sync <= 1'b1;
        @(posedge clk);
        frame_sync <= 1'b0;
        for (cycles = 0; cycles < 5000 && !p2_sample_valid; cycles = cycles + 1)
            @(posedge clk);
        if (!p2_sample_valid || !p2_connected || !p2_gun_aim_valid ||
            p2_device_id != 8'h63 || p2_buttons != 16'h6000 ||
            p2_raw_x != 9'h10d || p2_raw_y != 9'h080 ||
            p2_gun_x != 10'd511 || p2_gun_y != 8'd117)
            $fatal(1, "GunCon P2 sequencing/decoding failed id=%h buttons=%h raw=%h/%h norm=%d/%d",
                   p2_device_id, p2_buttons, p2_raw_x, p2_raw_y,
                   p2_gun_x, p2_gun_y);
        $display("GUNCON SNAC PASS");
        $finish;
    end

    // DATA is returned LSB first while the host clock is low. The controller
    // ACKs each complete byte with a short active-low pulse.
    always @(negedge serial_clk) begin
        if (selected) begin
            data_in <= response[byte_no][bit_no];
        end
    end

    always @(posedge serial_clk) begin
        if (selected) begin
            if (bit_no == 7) begin
                bit_no <= 0;
                byte_no <= (byte_no == 8) ? 8 : byte_no + 1;
                ack_in <= 1'b0;
                #20 ack_in <= 1'b1;
            end
            else
                bit_no <= bit_no + 1;
        end
    end

    always @(posedge clk) begin
        if (!selected) begin
            bit_no <= 0;
            byte_no <= 0;
            ack_in <= 1'b1;
            data_in <= 1'b1;
        end
    end

    // P1->P2 hand-off can assert the next select in the same clock edge that
    // releases the previous one, so there is no all-selects-high clock for
    // the model to observe. Re-arm the packet cursor on each select edge.
    always @(negedge select1_n or negedge select2_n) begin
        bit_no = 0;
        byte_no = 0;
        ack_in = 1'b1;
        data_in = 1'b1;
    end
endmodule
