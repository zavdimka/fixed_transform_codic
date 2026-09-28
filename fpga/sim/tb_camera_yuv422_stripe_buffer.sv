`timescale 1ns/1ps

module tb_camera_yuv422_stripe_buffer;
    logic pixel_clk = 0, read_clk = 0;
    always #7 pixel_clk = ~pixel_clk;
    always #5 read_clk = ~read_clk;
    logic pixel_rst_n = 0, read_rst_n = 0;
    logic pixel_vsync = 0, pixel_href = 0;
    logic [7:0] pixel_data = 0;
    logic stripe_valid, stripe_take = 0;
    logic [15:0] stripe_frame_id;
    logic [5:0] stripe_index;
    logic [6:0] read_ctu = 0;
    logic read_ctu_start = 0;
    logic row_ready = 1, row_valid;
    logic [5:0] row_index;
    logic [127:0] row_data;
    logic stripe_release = 0;
    logic overflow;
    logic [15:0] dropped_stripes;

    camera_yuv422_stripe_buffer8way #(.FRAME_WIDTH(32)) dut (
        .pixel_clk(pixel_clk), .pixel_rst_n(pixel_rst_n),
        .pixel_vsync(pixel_vsync), .pixel_href(pixel_href),
        .pixel_data(pixel_data), .read_clk(read_clk),
        .read_rst_n(read_rst_n), .stripe_valid(stripe_valid),
        .stripe_take(stripe_take), .stripe_frame_id(stripe_frame_id),
        .stripe_index(stripe_index), .read_ctu(read_ctu),
        .read_ctu_start(read_ctu_start), .row_ready(row_ready),
        .row_valid(row_valid), .row_index(row_index), .row_data(row_data),
        .stripe_release(stripe_release), .overflow(overflow),
        .dropped_stripes(dropped_stripes)
    );

    task automatic send_byte(input [7:0] value);
        begin
            @(negedge pixel_clk);
            pixel_data = value;
        end
    endtask

    task automatic send_line(input integer line);
        integer pair_index;
        begin
            @(negedge pixel_clk);
            // OV5640 asserts HREF with the first valid byte already present.
            pixel_href = 1;
            pixel_data = line * 32;
            send_byte(64 + line);
            send_byte(line * 32 + 1);
            send_byte(128 + line);
            for (pair_index = 1; pair_index < 16;
                 pair_index = pair_index + 1) begin
                send_byte(line * 32 + pair_index * 2);
                send_byte(64 + line + pair_index);
                send_byte(line * 32 + pair_index * 2 + 1);
                send_byte(128 + line + pair_index);
            end
            @(negedge pixel_clk);
            pixel_href = 0;
            pixel_data = 0;
            @(posedge pixel_clk);
        end
    endtask

    task automatic read_one_ctu(input integer ctu);
        integer rows_seen;
        integer lane;
        integer source_line;
        integer expected;
        begin
            @(negedge read_clk);
            read_ctu = ctu;
            read_ctu_start = 1;
            @(negedge read_clk);
            read_ctu_start = 0;
            rows_seen = 0;
            while (rows_seen < 32) begin
                @(negedge read_clk);
                if (row_valid) begin
                    if (row_index != rows_seen)
                        $fatal(1, "row order ctu=%0d got=%0d want=%0d",
                               ctu, row_index, rows_seen);
                    for (lane = 0; lane < (rows_seen < 16 ? 16 : 8);
                         lane = lane + 1) begin
                        if (rows_seen < 16)
                            expected = rows_seen * 32 + ctu * 16 + lane;
                        else begin
                            source_line = (rows_seen < 24)
                                ? (rows_seen - 16) * 2
                                : (rows_seen - 24) * 2;
                            expected = (rows_seen < 24 ? 64 : 128)
                                     + source_line + ctu * 8 + lane;
                        end
                        if (row_data[lane*8 +: 8] != (expected & 8'hff))
                            $fatal(1,
                                "sample ctu=%0d row=%0d lane=%0d got=%0d want=%0d",
                                ctu, rows_seen, lane,
                                row_data[lane*8 +: 8], expected & 8'hff);
                    end
                    rows_seen = rows_seen + 1;
                end
            end
        end
    endtask

    integer line;
    initial begin
        repeat (5) @(negedge pixel_clk);
        pixel_rst_n = 1;
        read_rst_n = 1;
        @(negedge pixel_clk);
        pixel_vsync = 1;
        @(negedge pixel_clk);
        pixel_vsync = 0;
        for (line = 0; line < 16; line = line + 1)
            send_line(line);
        wait (stripe_valid);
        if (stripe_frame_id != 1 || stripe_index != 0)
            $fatal(1, "stripe metadata");
        @(negedge read_clk);
        stripe_take = 1;
        @(negedge read_clk);
        stripe_take = 0;
        read_one_ctu(0);
        read_one_ctu(1);
        @(negedge read_clk);
        stripe_release = 1;
        @(negedge read_clk);
        stripe_release = 0;
        if (overflow || dropped_stripes != 0)
            $fatal(1, "unexpected overflow");
        $display("PASS camera_yuv422_stripe_buffer");
        $finish;
    end

    initial begin
        #1000000;
        $fatal(1, "timeout");
    end
endmodule
