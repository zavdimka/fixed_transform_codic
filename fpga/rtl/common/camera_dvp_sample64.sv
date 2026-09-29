module camera_dvp_sample64 (
    input  logic        pixel_clk,
    input  logic        pixel_rst_n,
    input  logic        pixel_vsync,
    input  logic        pixel_href,
    input  logic [7:0]  pixel_data,

    input  logic        read_clk,
    input  logic        read_rst_n,
    input  logic        arm,
    input  logic        vsync_active_high,
    input  logic        href_active_high,
    output logic        capture_busy,
    output logic        capture_done,
    output logic        capture_error,
    output logic [15:0] captured_lines,
    output logic [15:0] last_line_bytes,
    output logic [14:0] captured_words,

    input  logic        read_request,
    input  logic [13:0] read_word_address,
    output logic        read_valid,
    output logic [39:0] read_word
);
    localparam integer WORD_COUNT = 64;
    localparam integer SAMPLE_BYTES = WORD_COUNT * 5;

    // Only a 320-byte line prefix is retained. Two 20-bit memories map much
    // more economically than the former 32-line, 40-bit diagnostic frame.
    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    logic [19:0] memory_low [0:WORD_COUNT-1];
    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    logic [19:0] memory_high [0:WORD_COUNT-1];

    logic arm_toggle;
    logic capture_waiting, capture_seen_busy;
    (* async_reg = "true" *) logic [1:0] arm_pixel_sync;
    (* async_reg = "true" *) logic [1:0] done_read_sync;
    (* async_reg = "true" *) logic [1:0] busy_read_sync;
    (* async_reg = "true" *) logic [1:0] error_read_sync;
    logic done_toggle_pixel, busy_pixel, error_pixel;
    logic [15:0] captured_lines_pixel, last_line_bytes_pixel;
    logic [14:0] captured_words_pixel;

    logic read_pending;
    logic [5:0] read_address_pending;

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
            captured_words <= 15'd0;
            done_read_sync <= 2'b00;
            busy_read_sync <= 2'b00;
            error_read_sync <= 2'b00;
            read_pending <= 1'b0;
            read_address_pending <= 6'd0;
            read_valid <= 1'b0;
            read_word <= 40'd0;
        end else begin
            done_read_sync <= {done_read_sync[0], done_toggle_pixel};
            busy_read_sync <= {busy_read_sync[0], busy_pixel};
            error_read_sync <= {error_read_sync[0], error_pixel};
            capture_busy <= busy_read_sync[1];

            read_valid <= read_pending;
            read_pending <= read_request;
            if (read_request)
                read_address_pending <= read_word_address[5:0];
            if (read_pending)
                read_word <= {
                    memory_high[read_address_pending],
                    memory_low[read_address_pending]
                };

            if (arm && !capture_waiting) begin
                arm_toggle <= ~arm_toggle;
                capture_waiting <= 1'b1;
                capture_seen_busy <= 1'b0;
                capture_done <= 1'b0;
                capture_error <= 1'b0;
                captured_lines <= 16'd0;
                last_line_bytes <= 16'd0;
                captured_words <= 15'd0;
            end
            if (capture_waiting && busy_read_sync[1])
                capture_seen_busy <= 1'b1;
            if (capture_waiting && capture_seen_busy
                && !busy_read_sync[1]
                && done_read_sync[1] == arm_toggle) begin
                capture_waiting <= 1'b0;
                capture_done <= 1'b1;
                capture_error <= error_read_sync[1];
                captured_lines <= captured_lines_pixel;
                last_line_bytes <= last_line_bytes_pixel;
                captured_words <= captured_words_pixel;
            end
        end
    end

    typedef enum logic [1:0] {IDLE, WAIT_LINE, CAPTURE} state_t;
    state_t state;
    logic previous_href_active;
    logic sampled_vsync, sampled_href;
    logic [7:0] sampled_data;
    logic aligned_vsync, aligned_href;
    logic [7:0] aligned_data;
    logic [15:0] byte_count;
    logic [2:0] pack_count;
    logic [31:0] pack_bytes;
    logic [5:0] write_word_address;
    wire active_href = aligned_href == href_active_high;
    wire line_start = active_href && !previous_href_active;
    wire line_end = !active_href && previous_href_active;
    wire new_arm_pixel = arm_pixel_sync[1] != done_toggle_pixel;

    // Mirror the production capture phase so this diagnostic reports the
    // bytes actually presented to the stripe buffer.
    always_ff @(negedge pixel_clk) begin
        if (!pixel_rst_n) begin
            sampled_vsync <= 1'b0;
            sampled_href <= 1'b0;
            sampled_data <= 8'd0;
        end else begin
            sampled_vsync <= pixel_vsync;
            sampled_href <= pixel_href;
            sampled_data <= pixel_data;
        end
    end

    always_ff @(posedge pixel_clk) begin
        if (!pixel_rst_n) begin
            aligned_vsync <= 1'b0;
            aligned_href <= 1'b0;
            aligned_data <= 8'd0;
        end else begin
            aligned_vsync <= sampled_vsync;
            aligned_href <= sampled_href;
            aligned_data <= sampled_data;
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
            captured_words_pixel <= 15'd0;
            previous_href_active <= 1'b0;
            byte_count <= 16'd0;
            pack_count <= 3'd0;
            pack_bytes <= 32'd0;
            write_word_address <= 6'd0;
            state <= IDLE;
        end else begin
            arm_pixel_sync <= {arm_pixel_sync[0], arm_toggle};
            previous_href_active <= active_href;
            case (state)
                IDLE: begin
                    busy_pixel <= 1'b0;
                    if (new_arm_pixel) begin
                        busy_pixel <= 1'b1;
                        error_pixel <= 1'b0;
                        captured_lines_pixel <= 16'd0;
                        last_line_bytes_pixel <= 16'd0;
                        captured_words_pixel <= 15'd0;
                        byte_count <= 16'd0;
                        pack_count <= 3'd0;
                        write_word_address <= 6'd0;
                        state <= WAIT_LINE;
                    end
                end
                WAIT_LINE: begin
                    if (line_start) begin
                        byte_count <= 16'd1;
                        pack_count <= 3'd1;
                        pack_bytes[7:0] <= aligned_data;
                        state <= CAPTURE;
                    end
                end
                default: begin
                    if (active_href) begin
                        case (pack_count)
                            3'd0: pack_bytes[7:0] <= aligned_data;
                            3'd1: pack_bytes[15:8] <= aligned_data;
                            3'd2: pack_bytes[23:16] <= aligned_data;
                            3'd3: pack_bytes[31:24] <= aligned_data;
                            default: begin
                                memory_low[write_word_address]
                                    <= pack_bytes[19:0];
                                memory_high[write_word_address]
                                    <= {aligned_data, pack_bytes[31:20]};
                                write_word_address
                                    <= write_word_address + 1'b1;
                                captured_words_pixel
                                    <= captured_words_pixel + 1'b1;
                            end
                        endcase
                        byte_count <= byte_count + 1'b1;
                        pack_count <= pack_count == 4
                                          ? 3'd0 : pack_count + 1'b1;
                        if (byte_count + 1'b1 == SAMPLE_BYTES) begin
                            captured_lines_pixel <= 16'd1;
                            last_line_bytes_pixel <= SAMPLE_BYTES;
                            busy_pixel <= 1'b0;
                            done_toggle_pixel <= arm_pixel_sync[1];
                            state <= IDLE;
                        end
                    end else if (line_end) begin
                        error_pixel <= 1'b1;
                        last_line_bytes_pixel <= byte_count;
                        busy_pixel <= 1'b0;
                        done_toggle_pixel <= arm_pixel_sync[1];
                        state <= IDLE;
                    end
                end
            endcase
        end
    end

    logic unused_vsync;
    assign unused_vsync = aligned_vsync ^ vsync_active_high;
endmodule
