`timescale 1ns/1ps

module tb_receiver_sparse_base_idct8_latency;
    logic clk = 0;
    logic rst_n = 0;
    logic command_valid = 0;
    logic command_ready;
    logic pixel_valid;
    logic pixel_last;
    logic done, busy, saturated;
    logic [5:0] pixel_index;
    logic signed [15:0] pixel_residual;
    logic [6:0] pixel_ctu_index;
    logic [2:0] pixel_block_index;
    logic [1:0] pixel_plane, pixel_mode;
    integer cycles;

    always #5 clk = ~clk;

    receiver_sparse_base_idct8 dut (
        .clk(clk), .rst_n(rst_n),
        .command_valid(command_valid), .command_ready(command_ready),
        .command_ctu_index(7'd0), .command_block_index(3'd0),
        .command_plane(2'd0), .command_mode(2'd0),
        .command_quality(8'd24), .command_coefficients(72'd0),
        .pixel_valid(pixel_valid), .pixel_ready(1'b1),
        .pixel_index(pixel_index), .pixel_residual(pixel_residual),
        .pixel_last(pixel_last), .pixel_ctu_index(pixel_ctu_index),
        .pixel_block_index(pixel_block_index), .pixel_plane(pixel_plane),
        .pixel_mode(pixel_mode), .done(done), .busy(busy),
        .saturated(saturated)
    );

    initial begin
        repeat (5) @(posedge clk);
        rst_n <= 1;
        @(posedge clk);
        while (!command_ready) @(posedge clk);
        command_valid <= 1;
        @(posedge clk);
        command_valid <= 0;
        cycles = 0;
        while (!(pixel_valid && pixel_last)) begin
            @(posedge clk);
            cycles = cycles + 1;
            if (cycles > 300) $fatal(1, "sparse IDCT timeout");
        end
        $display("SPARSE_IDCT_COMMAND_TO_LAST_CYCLES=%0d", cycles);
        $finish;
    end
endmodule
