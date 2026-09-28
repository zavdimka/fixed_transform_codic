module camera_yuv422_stripe_buffer8way #(
    parameter integer FRAME_WIDTH = 1280,
    parameter integer FRAME_HEIGHT = 720,
    parameter integer STRIPE_HEIGHT = 16,
    parameter integer CTU_COUNT = FRAME_WIDTH / 16
) (
    input logic pixel_clk, pixel_rst_n, pixel_vsync, pixel_href,
    input logic [7:0] pixel_data,
    input logic read_clk, read_rst_n,
    output logic stripe_valid,
    input logic stripe_take,
    output logic [15:0] stripe_frame_id,
    output logic [5:0] stripe_index,
    input logic [6:0] read_ctu,
    input logic read_ctu_start, row_ready,
    output logic row_valid,
    output logic [5:0] row_index,
    output logic [127:0] row_data,
    input logic stripe_release,
    output logic overflow,
    output logic [15:0] dropped_stripes
);
    localparam integer BYTES_PER_LINE = FRAME_WIDTH * 2;
    localparam integer Y_WORDS_PER_LINE = FRAME_WIDTH / 8;
    localparam integer C_WORDS_PER_LINE = FRAME_WIDTH / 16;
    localparam integer Y_BANK_WORDS = STRIPE_HEIGHT * Y_WORDS_PER_LINE;
    localparam integer C_BANK_WORDS = (STRIPE_HEIGHT / 2) * C_WORDS_PER_LINE;
    localparam integer Y_DEPTH = 2 * Y_BANK_WORDS;
    localparam integer C_DEPTH = 2 * C_BANK_WORDS;
    localparam integer Y_AW = $clog2(Y_DEPTH);
    localparam integer C_AW = $clog2(C_DEPTH);

`define CAMERA_RAM8(name, depth) \
    (* ram_style = "block", syn_ramstyle = "block_ram" *) \
    logic [7:0] name [0:depth-1]
    `CAMERA_RAM8(y0, Y_DEPTH); `CAMERA_RAM8(y1, Y_DEPTH);
    `CAMERA_RAM8(y2, Y_DEPTH); `CAMERA_RAM8(y3, Y_DEPTH);
    `CAMERA_RAM8(y4, Y_DEPTH); `CAMERA_RAM8(y5, Y_DEPTH);
    `CAMERA_RAM8(y6, Y_DEPTH); `CAMERA_RAM8(y7, Y_DEPTH);
    `CAMERA_RAM8(cb0, C_DEPTH); `CAMERA_RAM8(cb1, C_DEPTH);
    `CAMERA_RAM8(cb2, C_DEPTH); `CAMERA_RAM8(cb3, C_DEPTH);
    `CAMERA_RAM8(cb4, C_DEPTH); `CAMERA_RAM8(cb5, C_DEPTH);
    `CAMERA_RAM8(cb6, C_DEPTH); `CAMERA_RAM8(cb7, C_DEPTH);
    `CAMERA_RAM8(cr0, C_DEPTH); `CAMERA_RAM8(cr1, C_DEPTH);
    `CAMERA_RAM8(cr2, C_DEPTH); `CAMERA_RAM8(cr3, C_DEPTH);
    `CAMERA_RAM8(cr4, C_DEPTH); `CAMERA_RAM8(cr5, C_DEPTH);
    `CAMERA_RAM8(cr6, C_DEPTH); `CAMERA_RAM8(cr7, C_DEPTH);
`undef CAMERA_RAM8

    logic pixel_bank;
    logic [1:0] commit_toggle_pixel, release_toggle_read;
    (* async_reg = "true" *) logic [1:0] release_pixel_sync_1;
    (* async_reg = "true" *) logic [1:0] release_pixel_sync_2;
    (* async_reg = "true" *) logic [1:0] commit_read_sync_1;
    (* async_reg = "true" *) logic [1:0] commit_read_sync_2;
    logic [15:0] bank_frame_id [0:1];
    logic [5:0] bank_stripe_index [0:1];
    logic previous_vsync, previous_href, stripe_accepting;
    logic [15:0] frame_id_pixel;
    logic [9:0] line_index;
    logic [11:0] byte_index;
    wire frame_start = pixel_vsync && !previous_vsync;
    wire line_start = pixel_href && !previous_href;
    wire line_end = !pixel_href && previous_href;
    wire bank_available =
        release_pixel_sync_2[pixel_bank] == commit_toggle_pixel[pixel_bank];
    wire [3:0] stripe_line = line_index[3:0];
    wire [10:0] pixel_index = byte_index[11:1];
    wire [2:0] y_lane = pixel_index[2:0];
    wire [2:0] c_lane = pixel_index[3:1];
    logic [Y_AW-1:0] y_write_address;
    logic [C_AW-1:0] c_write_address;

    always_comb begin
        y_write_address = pixel_bank * Y_BANK_WORDS
                        + stripe_line * Y_WORDS_PER_LINE
                        + (pixel_index >> 3);
        c_write_address = pixel_bank * C_BANK_WORDS
                        + stripe_line[3:1] * C_WORDS_PER_LINE
                        + (pixel_index >> 4);
    end

    always_ff @(posedge pixel_clk) begin
        if (!pixel_rst_n) begin
            pixel_bank <= 0; commit_toggle_pixel <= 0;
            release_pixel_sync_1 <= 0; release_pixel_sync_2 <= 0;
            previous_vsync <= 0; previous_href <= 0;
            frame_id_pixel <= 0; line_index <= 0; byte_index <= 0;
            stripe_accepting <= 0; overflow <= 0; dropped_stripes <= 0;
        end else begin
            release_pixel_sync_1 <= release_toggle_read;
            release_pixel_sync_2 <= release_pixel_sync_1;
            previous_vsync <= pixel_vsync;
            previous_href <= pixel_href;
            if (frame_start) begin
                frame_id_pixel <= frame_id_pixel + 1'b1;
                line_index <= 0; byte_index <= 0; stripe_accepting <= 0;
            end
            if (line_start) begin
                // OV5640 presents the first valid byte on the same PCLK on
                // which HREF becomes active. Count and store that byte here;
                // dropping it shortens a hardware line to 2559 bytes.
                byte_index <= 1;
                if (stripe_line == 0)
                    stripe_accepting <= bank_available;
                if (bank_available)
                    y0[y_write_address] <= pixel_data;
            end else if (pixel_href) begin
                byte_index <= byte_index + 1'b1;
                if (stripe_accepting) begin
                    if (!byte_index[0])
                        case (y_lane)
                            0: y0[y_write_address] <= pixel_data;
                            1: y1[y_write_address] <= pixel_data;
                            2: y2[y_write_address] <= pixel_data;
                            3: y3[y_write_address] <= pixel_data;
                            4: y4[y_write_address] <= pixel_data;
                            5: y5[y_write_address] <= pixel_data;
                            6: y6[y_write_address] <= pixel_data;
                            default: y7[y_write_address] <= pixel_data;
                        endcase
                    else if (!stripe_line[0]) begin
                        if (!pixel_index[0])
                            case (c_lane)
                                0: cb0[c_write_address] <= pixel_data;
                                1: cb1[c_write_address] <= pixel_data;
                                2: cb2[c_write_address] <= pixel_data;
                                3: cb3[c_write_address] <= pixel_data;
                                4: cb4[c_write_address] <= pixel_data;
                                5: cb5[c_write_address] <= pixel_data;
                                6: cb6[c_write_address] <= pixel_data;
                                default: cb7[c_write_address] <= pixel_data;
                            endcase
                        else
                            case (c_lane)
                                0: cr0[c_write_address] <= pixel_data;
                                1: cr1[c_write_address] <= pixel_data;
                                2: cr2[c_write_address] <= pixel_data;
                                3: cr3[c_write_address] <= pixel_data;
                                4: cr4[c_write_address] <= pixel_data;
                                5: cr5[c_write_address] <= pixel_data;
                                6: cr6[c_write_address] <= pixel_data;
                                default: cr7[c_write_address] <= pixel_data;
                            endcase
                    end
                end
            end
            if (line_end) begin
                byte_index <= 0;
                if (line_index + 1 < FRAME_HEIGHT) begin
                    line_index <= line_index + 1'b1;
                end else begin
                    line_index <= 0;
                    frame_id_pixel <= frame_id_pixel + 1'b1;
                end
                if (stripe_line == STRIPE_HEIGHT - 1
                    && line_index < FRAME_HEIGHT) begin
                    stripe_accepting <= 0;
                    if (stripe_accepting && byte_index == BYTES_PER_LINE) begin
                        bank_frame_id[pixel_bank] <= frame_id_pixel;
                        bank_stripe_index[pixel_bank] <= line_index[9:4];
                        commit_toggle_pixel[pixel_bank] <=
                            ~commit_toggle_pixel[pixel_bank];
                        pixel_bank <= ~pixel_bank;
                    end else begin
                        overflow <= 1;
                        dropped_stripes <= dropped_stripes + 1'b1;
                    end
                end
            end
        end
    end

    logic read_bank, bank_active, ctu_active, issue_chunk;
    logic [5:0] issue_row;
    logic [1:0] read_pipe;
    logic [Y_AW-1:0] y_read_address;
    logic [C_AW-1:0] c_read_address;
    logic [7:0] yr0,yr1,yr2,yr3,yr4,yr5,yr6,yr7;
    logic [7:0] cbr0,cbr1,cbr2,cbr3,cbr4,cbr5,cbr6,cbr7;
    logic [7:0] crr0,crr1,crr2,crr3,crr4,crr5,crr6,crr7;
    logic [63:0] row_low;
    wire [63:0] y_word = {yr7,yr6,yr5,yr4,yr3,yr2,yr1,yr0};
    wire [63:0] cb_word = {cbr7,cbr6,cbr5,cbr4,cbr3,cbr2,cbr1,cbr0};
    wire [63:0] cr_word = {crr7,crr6,crr5,crr4,crr3,crr2,crr1,crr0};
    wire read_bank_pending =
        commit_read_sync_2[read_bank] != release_toggle_read[read_bank];

    always_ff @(posedge read_clk) begin
        yr0<=y0[y_read_address]; yr1<=y1[y_read_address];
        yr2<=y2[y_read_address]; yr3<=y3[y_read_address];
        yr4<=y4[y_read_address]; yr5<=y5[y_read_address];
        yr6<=y6[y_read_address]; yr7<=y7[y_read_address];
        cbr0<=cb0[c_read_address]; cbr1<=cb1[c_read_address];
        cbr2<=cb2[c_read_address]; cbr3<=cb3[c_read_address];
        cbr4<=cb4[c_read_address]; cbr5<=cb5[c_read_address];
        cbr6<=cb6[c_read_address]; cbr7<=cb7[c_read_address];
        crr0<=cr0[c_read_address]; crr1<=cr1[c_read_address];
        crr2<=cr2[c_read_address]; crr3<=cr3[c_read_address];
        crr4<=cr4[c_read_address]; crr5<=cr5[c_read_address];
        crr6<=cr6[c_read_address]; crr7<=cr7[c_read_address];
    end

    always_ff @(posedge read_clk) begin
        if (!read_rst_n) begin
            commit_read_sync_1<=0; commit_read_sync_2<=0;
            release_toggle_read<=0; read_bank<=0; bank_active<=0;
            ctu_active<=0; stripe_valid<=0; stripe_frame_id<=0;
            stripe_index<=0; issue_row<=0; issue_chunk<=0; read_pipe<=0;
            row_valid<=0; row_index<=0; row_data<=0; row_low<=0;
            y_read_address<=0; c_read_address<=0;
        end else begin
            commit_read_sync_1 <= commit_toggle_pixel;
            commit_read_sync_2 <= commit_read_sync_1;
            if (!bank_active && read_bank_pending) begin
                stripe_valid <= 1;
                stripe_frame_id <= bank_frame_id[read_bank];
                stripe_index <= bank_stripe_index[read_bank];
            end
            if (stripe_valid && stripe_take) begin
                stripe_valid<=0; bank_active<=1; ctu_active<=0;
                row_valid<=0; read_pipe<=0;
            end
            if (bank_active && read_ctu_start) begin
                ctu_active<=1; issue_row<=0; issue_chunk<=0;
                row_valid<=0; read_pipe<=0; row_low<=0;
            end
            if (ctu_active && !row_valid && read_pipe == 0) begin
                if (issue_row < 16)
                    y_read_address <= read_bank * Y_BANK_WORDS
                                    + issue_row * Y_WORDS_PER_LINE
                                    + read_ctu * 2 + issue_chunk;
                else
                    c_read_address <= read_bank * C_BANK_WORDS
                                    + (issue_row < 24
                                       ? issue_row - 16 : issue_row - 24)
                                      * C_WORDS_PER_LINE + read_ctu;
                read_pipe <= 1;
            end else if (read_pipe == 1) begin
                read_pipe <= 2;
            end else if (read_pipe == 2) begin
                read_pipe <= 0;
                if (issue_row < 16 && !issue_chunk) begin
                    row_low <= y_word;
                    issue_chunk <= 1;
                end else begin
                    row_index <= issue_row;
                    if (issue_row < 16) row_data <= {y_word, row_low};
                    else if (issue_row < 24) row_data <= {64'd0, cb_word};
                    else row_data <= {64'd0, cr_word};
                    row_valid <= 1;
                end
            end
            if (row_valid && row_ready) begin
                row_valid<=0; issue_chunk<=0; row_low<=0;
                if (issue_row == 31) ctu_active<=0;
                else issue_row <= issue_row + 1'b1;
            end
            if (bank_active && stripe_release) begin
                bank_active<=0; ctu_active<=0; row_valid<=0; read_pipe<=0;
                release_toggle_read[read_bank] <= commit_read_sync_2[read_bank];
                read_bank <= ~read_bank;
            end
        end
    end
endmodule
