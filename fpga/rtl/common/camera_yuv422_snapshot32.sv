module camera_yuv422_snapshot32 #(
    parameter integer FRAME_WIDTH = 1280,
    parameter integer CAPTURE_LINES = 32,
    parameter integer BYTES_PER_PIXEL = 2,
    parameter integer BYTES_PER_LINE = FRAME_WIDTH * BYTES_PER_PIXEL,
    parameter integer CAPTURE_BYTES = BYTES_PER_LINE * CAPTURE_LINES,
    parameter integer WORD_COUNT = CAPTURE_BYTES / 5,
    parameter integer WORD_ADDRESS_WIDTH = $clog2(WORD_COUNT)
) (
    input  logic                          pixel_clk,
    input  logic                          pixel_rst_n,
    input  logic                          pixel_vsync,
    input  logic                          pixel_href,
    input  logic [7:0]                    pixel_data,

    input  logic                          read_clk,
    input  logic                          read_rst_n,
    input  logic                          arm,
    input  logic                          vsync_active_high,
    input  logic                          href_active_high,
    output logic                          capture_busy,
    output logic                          capture_done,
    output logic                          capture_error,
    output logic [15:0]                   captured_lines,
    output logic [15:0]                   last_line_bytes,
    output logic [WORD_ADDRESS_WIDTH:0]   captured_words,

    input  logic                          read_request,
    input  logic [WORD_ADDRESS_WIDTH-1:0] read_word_address,
    output logic                          read_valid,
    output logic [39:0]                   read_word
);
    localparam logic [15:0] CAPTURE_LINES_16 = 16'(CAPTURE_LINES);
    localparam logic [15:0] BYTES_PER_LINE_16 = 16'(BYTES_PER_LINE);
    initial begin
        if ((CAPTURE_BYTES % 5) != 0)
            $error("camera snapshot size must be divisible by five bytes");
    end

    // A Trion 5-kbit EBR is naturally 20 bits wide at depth 256.  Splitting
    // each five-byte capture word into two 20-bit memories avoids the 20%%
    // waste caused by an inferred 8-bit-wide 512x10 organization.
    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    logic [19:0] memory_low [0:WORD_COUNT-1];
    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    logic [19:0] memory_high [0:WORD_COUNT-1];

    logic arm_toggle;
    logic capture_waiting;
    logic capture_seen_busy;
    (* async_reg = "true" *) logic [1:0] arm_pixel_sync;
    (* async_reg = "true" *) logic [1:0] done_read_sync;
    (* async_reg = "true" *) logic [1:0] busy_read_sync;
    (* async_reg = "true" *) logic [1:0] error_read_sync;

    logic done_toggle_pixel;
    logic busy_pixel;
    logic error_pixel;
    logic [15:0] captured_lines_pixel;
    logic [15:0] last_line_bytes_pixel;
    logic [WORD_ADDRESS_WIDTH:0] captured_words_pixel;

    typedef enum logic [1:0] {SNAP_IDLE, SNAP_WAIT_FRAME, SNAP_CAPTURE}
        snapshot_state_t;
    snapshot_state_t snapshot_state;
    logic previous_vsync_active;
    logic previous_href_active;
    logic line_open;
    logic line_accepting;
    logic [15:0] line_byte_count;
    logic [2:0] pack_count;
    logic [31:0] pack_bytes;
    logic [WORD_ADDRESS_WIDTH-1:0] write_word_address;

    wire active_vsync = pixel_vsync == vsync_active_high;
    wire active_href = pixel_href == href_active_high;
    wire frame_start = active_vsync && !previous_vsync_active;
    wire line_start = active_href && !previous_href_active;
    wire line_end = !active_href && previous_href_active;
    wire new_arm_pixel = arm_pixel_sync[1] != done_toggle_pixel;

    always_ff @(posedge read_clk) begin
        if (!read_rst_n) begin
            arm_toggle <= 1'b0;
            capture_waiting <= 1'b0;
            capture_seen_busy <= 1'b0;
            capture_busy <= 1'b0;
            capture_done <= 1'b0;
            capture_error <= 1'b0;
            captured_lines <= 16'd0;
            last_line_bytes <= 16'd0;
            captured_words <= '0;
            done_read_sync <= 2'b00;
            busy_read_sync <= 2'b00;
            error_read_sync <= 2'b00;
            read_valid <= 1'b0;
            read_word <= 40'd0;
        end else begin
            done_read_sync <= {done_read_sync[0], done_toggle_pixel};
            busy_read_sync <= {busy_read_sync[0], busy_pixel};
            error_read_sync <= {error_read_sync[0], error_pixel};
            capture_busy <= busy_read_sync[1];
            read_valid <= read_request;
            if (read_request)
                read_word <= {
                    memory_high[read_word_address],
                    memory_low[read_word_address]
                };

            if (arm && !capture_waiting) begin
                arm_toggle <= ~arm_toggle;
                capture_waiting <= 1'b1;
                capture_seen_busy <= 1'b0;
                capture_done <= 1'b0;
                capture_error <= 1'b0;
                captured_lines <= 16'd0;
                last_line_bytes <= 16'd0;
                captured_words <= '0;
            end

            if (capture_waiting && busy_read_sync[1])
                capture_seen_busy <= 1'b1;

            if (capture_waiting && capture_seen_busy
                && !busy_read_sync[1]
                && (done_read_sync[1] == arm_toggle)) begin
                capture_waiting <= 1'b0;
                capture_done <= 1'b1;
                capture_error <= error_read_sync[1];
                captured_lines <= captured_lines_pixel;
                last_line_bytes <= last_line_bytes_pixel;
                captured_words <= captured_words_pixel;
            end
        end
    end

    always_ff @(posedge pixel_clk) begin
        if (!pixel_rst_n) begin
            arm_pixel_sync <= 2'b00;
            done_toggle_pixel <= 1'b0;
            busy_pixel <= 1'b0;
            error_pixel <= 1'b0;
            captured_lines_pixel <= 16'd0;
            last_line_bytes_pixel <= 16'd0;
            captured_words_pixel <= '0;
            snapshot_state <= SNAP_IDLE;
            previous_vsync_active <= 1'b0;
            previous_href_active <= 1'b0;
            line_open <= 1'b0;
            line_accepting <= 1'b0;
            line_byte_count <= 16'd0;
            pack_count <= 3'd0;
            pack_bytes <= 32'd0;
            write_word_address <= '0;
        end else begin
            arm_pixel_sync <= {arm_pixel_sync[0], arm_toggle};
            previous_vsync_active <= active_vsync;
            previous_href_active <= active_href;

            case (snapshot_state)
                SNAP_IDLE: begin
                    busy_pixel <= 1'b0;
                    if (new_arm_pixel) begin
                        busy_pixel <= 1'b1;
                        error_pixel <= 1'b0;
                        captured_lines_pixel <= 16'd0;
                        last_line_bytes_pixel <= 16'd0;
                        captured_words_pixel <= '0;
                        write_word_address <= '0;
                        pack_count <= 3'd0;
                        line_open <= 1'b0;
                        line_accepting <= 1'b0;
                        snapshot_state <= SNAP_WAIT_FRAME;
                    end
                end

                SNAP_WAIT_FRAME: begin
                    if (frame_start)
                        snapshot_state <= SNAP_CAPTURE;
                end

                default: begin // SNAP_CAPTURE
                    if (line_start) begin
                        line_open <= 1'b1;
                        line_accepting <= 1'b1;
                        line_byte_count <= 16'd1;
                        pack_count <= 3'd1;
                        pack_bytes[7:0] <= pixel_data;
                    end else if (active_href && line_open
                                 && line_accepting) begin
                        case (pack_count)
                            3'd0: pack_bytes[7:0] <= pixel_data;
                            3'd1: pack_bytes[15:8] <= pixel_data;
                            3'd2: pack_bytes[23:16] <= pixel_data;
                            3'd3: pack_bytes[31:24] <= pixel_data;
                            default: begin
                                memory_low[write_word_address] <=
                                    {pack_bytes[19:0]};
                                memory_high[write_word_address] <= {
                                    pixel_data, pack_bytes[31:20]
                                };
                                write_word_address <=
                                    write_word_address + 1'b1;
                                captured_words_pixel <=
                                    captured_words_pixel + 1'b1;
                            end
                        endcase
                        line_byte_count <= line_byte_count + 1'b1;
                        if (line_byte_count + 1'b1 == BYTES_PER_LINE_16)
                            line_accepting <= 1'b0;
                        if (pack_count == 4)
                            pack_count <= 3'd0;
                        else
                            pack_count <= pack_count + 1'b1;
                    end

                    if (line_end && line_open) begin
                        line_open <= 1'b0;
                        line_accepting <= 1'b0;
                        last_line_bytes_pixel <= line_byte_count;
                        if ((line_byte_count != BYTES_PER_LINE_16)
                            || (pack_count != 0))
                            error_pixel <= 1'b1;
                        if (captured_lines_pixel + 1'b1
                            == CAPTURE_LINES_16) begin
                            captured_lines_pixel <=
                                captured_lines_pixel + 1'b1;
                            busy_pixel <= 1'b0;
                            done_toggle_pixel <= arm_pixel_sync[1];
                            snapshot_state <= SNAP_IDLE;
                        end else begin
                            captured_lines_pixel <=
                                captured_lines_pixel + 1'b1;
                        end
                    end

                    // A new frame before all requested lines is a malformed
                    // capture.  Finish it rather than mixing two frames.
                    if (frame_start && (captured_lines_pixel != 0)) begin
                        error_pixel <= 1'b1;
                        busy_pixel <= 1'b0;
                        done_toggle_pixel <= arm_pixel_sync[1];
                        snapshot_state <= SNAP_IDLE;
                    end
                end
            endcase
        end
    end
endmodule
