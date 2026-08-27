`timescale 1ns/1ps

module tb_jpark_gun_gain;
    reg        enable;
    reg  [7:0] p1_x_in, p1_y_in, p2_x_in, p2_y_in;
    wire [7:0] p1_x_out, p1_y_out, p2_x_out, p2_y_out;
    integer value;
    integer expected;

    s32_jpark_gun_gain dut (
        .enable(enable),
        .p1_x_in(p1_x_in), .p1_y_in(p1_y_in),
        .p2_x_in(p2_x_in), .p2_y_in(p2_y_in),
        .p1_x_out(p1_x_out), .p1_y_out(p1_y_out),
        .p2_x_out(p2_x_out), .p2_y_out(p2_y_out)
    );

    task automatic check(input condition, input [255:0] message);
        if (!condition) begin
            $display("FAIL: %0s", message);
            $fatal(1);
        end
    endtask

    initial begin
        p1_x_in = 8'h00; p1_y_in = 8'h80;
        p2_x_in = 8'hff; p2_y_in = 8'h7f;

        enable = 1'b0;
        #1;
        check({p1_x_out, p1_y_out, p2_x_out, p2_y_out} ===
              {p1_x_in,  p1_y_in,  p2_x_in,  p2_y_in},
              "Alien 3 bypass is bit-identical");

        enable = 1'b1;
        #1;
        check(p1_x_out == 8'h40 && p1_y_out == 8'h80 &&
              p2_x_out == 8'hbf && p2_y_out == 8'h7f,
              "Jurassic Park endpoints and centre use centered half gain");

        for (value = 0; value < 256; value = value + 1) begin
            p1_x_in = value[7:0];
            p1_y_in = value[7:0];
            p2_x_in = value[7:0];
            p2_y_in = value[7:0];
            expected = 128 + (($signed(value) - 128) >>> 1);
            #1;
            check(p1_x_out == expected[7:0] && p1_y_out == expected[7:0] &&
                  p2_x_out == expected[7:0] && p2_y_out == expected[7:0],
                  "all Jurassic Park channels follow centered half gain");
        end

        enable = 1'b0;
        for (value = 0; value < 256; value = value + 1) begin
            p1_x_in = value[7:0];
            p1_y_in = value[7:0];
            p2_x_in = value[7:0];
            p2_y_in = value[7:0];
            #1;
            check(p1_x_out == value[7:0] && p1_y_out == value[7:0] &&
                  p2_x_out == value[7:0] && p2_y_out == value[7:0],
                  "all Alien 3 values bypass unchanged");
        end

        $display("JPARK GUN GAIN PASS");
        $finish;
    end
endmodule
