`timescale 1ns/1ps

module tb_receiver_test_pattern;
    logic pixel_clk = 1'b0;
    logic rst_n = 1'b0;
    logic [1:0] mode = 2'd0;
    logic [11:0] x = 12'd0;
    logic [9:0] y = 10'd0;
    logic [23:0] rgb;

    receiver_test_pattern dut (
        .pixel_clk(pixel_clk),
        .rst_n(rst_n),
        .mode(mode),
        .x(x),
        .y(y),
        .rgb(rgb)
    );

    always #5 pixel_clk = ~pixel_clk;

    task automatic check_pixel(
        input logic [1:0] sample_mode,
        input logic [11:0] sample_x,
        input logic [9:0] sample_y,
        input logic [23:0] expected
    );
        begin
            @(negedge pixel_clk);
            mode = sample_mode;
            x = sample_x;
            y = sample_y;
            repeat (5) @(posedge pixel_clk);
            #1;
            if (rgb !== expected) begin
                $fatal(1,
                       "mode=%0d x=%0d y=%0d rgb=%06x expected=%06x",
                       sample_mode, sample_x, sample_y, rgb, expected);
            end
        end
    endtask

    initial begin
        repeat (2) @(posedge pixel_clk);
        rst_n = 1'b1;

        // The seven coloured bars retain a guaranteed brightness floor.
        check_pixel(2'd1, 12'd0,    10'd0,   24'h808080);
        check_pixel(2'd1, 12'd200,  10'd0,   24'h808000);
        check_pixel(2'd1, 12'd400,  10'd719, 24'h00D9D9);
        check_pixel(2'd1, 12'd1000, 10'd719, 24'h0000D9);
        check_pixel(2'd1, 12'd1200, 10'd0,   24'h101010);

        if (rgb == 24'h000000)
            $fatal(1, "diagnostic mode unexpectedly became black");

        $display("PASS: receiver_test_pattern gradient bars");
        $finish;
    end
endmodule
