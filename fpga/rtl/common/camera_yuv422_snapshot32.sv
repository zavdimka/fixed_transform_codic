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

    localparam integer MEMORY_WORD_COUNT = CAPTURE_BYTES * 8 / 10;
    localparam integer MEMORY_ADDRESS_WIDTH = $clog2(MEMORY_WORD_COUNT);

    // One native 512x10 stream consumes exactly one Trion 5-kbit EBR.  The
    // 81920-byte snapshot therefore occupies 65536 10-bit words / 128 EBRs.
    // The SPI-facing port still reconstructs the original five-byte words.
    logic memory_write_enable;
    logic [MEMORY_ADDRESS_WIDTH-1:0] memory_write_address;
    logic [9:0] memory_write_data;
    logic [MEMORY_ADDRESS_WIDTH-1:0] memory_read_address;
    logic [9:0] memory_read_data;

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

    typedef enum logic [1:0] {
        SNAP_IDLE, SNAP_WAIT_FRAME, SNAP_CAPTURE, SNAP_FLUSH
    }
        snapshot_state_t;
    snapshot_state_t snapshot_state;
    logic previous_vsync_active;
    logic previous_href_active;
    logic line_open;
    logic line_accepting;
    logic [15:0] line_byte_count;
    logic [2:0] pack_count;
    logic [31:0] pack_bytes;
    logic [39:0] pending_group;
    logic pending_group_valid;
    logic [1:0] pending_chunk;

    typedef enum logic [2:0] {
        READ_IDLE, READ_WAIT_RAM, READ_WAIT_GROUP, READ_WAIT_OUTPUT,
        READ_CHUNK0, READ_CHUNK1, READ_CHUNK2, READ_CHUNK3
    } read_state_t;
    read_state_t read_state;

    wire active_vsync = pixel_vsync == vsync_active_high;
    wire active_href = pixel_href == href_active_high;
    wire frame_start = active_vsync && !previous_vsync_active;
    wire line_start = active_href && !previous_href_active;
    wire line_end = !active_href && previous_href_active;
    wire new_arm_pixel = arm_pixel_sync[1] != done_toggle_pixel;

    assign memory_write_enable = pending_group_valid;
    assign memory_write_data =
        pending_group[pending_chunk * 10 +: 10];

`ifdef EFINIX_T20_NATIVE_EBR
    // Verific otherwise decomposes a 10-bit inferred memory as 8+2 bits and
    // spends 160 blocks.  Explicit native-width banks retain all ten data
    // bits in each 512x10 EBR, reducing the snapshot to exactly 128 blocks.
    wire [9:0] native_read_data [0:127];
    logic [9:0] native_group_data [0:15];
    logic [6:0] native_read_bank;
    logic [3:0] native_group_select;
    integer native_group_index;
    genvar native_bank_index;
    generate
        for (native_bank_index = 0; native_bank_index < 128;
             native_bank_index = native_bank_index + 1) begin : native_banks
            EFX_DPRAM_5K #(
                .READ_WIDTH_A(10), .WRITE_WIDTH_A(10),
                .READ_WIDTH_B(10), .WRITE_WIDTH_B(10),
                .OUTPUT_REG_A(1'b0), .OUTPUT_REG_B(1'b0),
                .WRITE_MODE_A("READ_FIRST"),
                .WRITE_MODE_B("READ_FIRST")
            ) snapshot_ebr (
                .CLKA(pixel_clk), .CLKEA(1'b1),
                .WEA(memory_write_enable
                     && (memory_write_address[15:9]
                         == native_bank_index)),
                .ADDRA(memory_write_address[8:0]),
                .WDATAA(memory_write_data), .RDATAA(),
                .CLKB(read_clk), .CLKEB(1'b1), .WEB(1'b0),
                .ADDRB(memory_read_address[8:0]), .WDATAB(10'd0),
                .RDATAB(native_read_data[native_bank_index])
            );
        end
    endgenerate

    // Two registered mux levels keep the 128-bank readback path away from
    // the codec timing domain's critical combinational paths.
    always_ff @(posedge read_clk) begin
        native_read_bank <= memory_read_address[15:9];
        for (native_group_index = 0; native_group_index < 16;
             native_group_index = native_group_index + 1)
            native_group_data[native_group_index] <= native_read_data[
                native_group_index * 8 + native_read_bank[2:0]
            ];
        native_group_select <= native_read_bank[6:3];
        memory_read_data <= native_group_data[native_group_select];
    end
`else
    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    logic [9:0] snapshot_memory [0:MEMORY_WORD_COUNT-1];

    always_ff @(posedge pixel_clk) begin
        if (memory_write_enable)
            snapshot_memory[memory_write_address] <= memory_write_data;
    end

    logic [9:0] simulation_read_pipe0;
    logic [9:0] simulation_read_pipe1;
    always_ff @(posedge read_clk) begin
        simulation_read_pipe0 <= snapshot_memory[memory_read_address];
        simulation_read_pipe1 <= simulation_read_pipe0;
        memory_read_data <= simulation_read_pipe1;
    end
`endif

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
            memory_read_address <= '0;
            read_state <= READ_IDLE;
        end else begin
            done_read_sync <= {done_read_sync[0], done_toggle_pixel};
            busy_read_sync <= {busy_read_sync[0], busy_pixel};
            error_read_sync <= {error_read_sync[0], error_pixel};
            capture_busy <= busy_read_sync[1];
            read_valid <= 1'b0;
            case (read_state)
                READ_IDLE: begin
                    if (read_request) begin
                        memory_read_address <= {read_word_address, 2'b00};
                        read_state <= READ_WAIT_RAM;
                    end
                end
                READ_WAIT_RAM: begin
                    memory_read_address <= memory_read_address + 1'b1;
                    read_state <= READ_WAIT_GROUP;
                end
                READ_WAIT_GROUP: begin
                    memory_read_address <= memory_read_address + 1'b1;
                    read_state <= READ_WAIT_OUTPUT;
                end
                READ_WAIT_OUTPUT: begin
                    memory_read_address <= memory_read_address + 1'b1;
                    read_state <= READ_CHUNK0;
                end
                READ_CHUNK0: begin
                    read_word[9:0] <= memory_read_data;
                    read_state <= READ_CHUNK1;
                end
                READ_CHUNK1: begin
                    read_word[19:10] <= memory_read_data;
                    read_state <= READ_CHUNK2;
                end
                READ_CHUNK2: begin
                    read_word[29:20] <= memory_read_data;
                    read_state <= READ_CHUNK3;
                end
                default: begin
                    read_word[39:30] <= memory_read_data;
                    read_valid <= 1'b1;
                    read_state <= READ_IDLE;
                end
            endcase

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
            pending_group <= 40'd0;
            pending_group_valid <= 1'b0;
            pending_chunk <= 2'd0;
            memory_write_address <= '0;
        end else begin
            arm_pixel_sync <= {arm_pixel_sync[0], arm_toggle};
            previous_vsync_active <= active_vsync;
            previous_href_active <= active_href;

            if (pending_group_valid) begin
                memory_write_address <= memory_write_address + 1'b1;
                if (pending_chunk == 3) begin
                    pending_group_valid <= 1'b0;
                    pending_chunk <= 2'd0;
                end else begin
                    pending_chunk <= pending_chunk + 1'b1;
                end
            end

            case (snapshot_state)
                SNAP_IDLE: begin
                    busy_pixel <= 1'b0;
                    if (new_arm_pixel) begin
                        busy_pixel <= 1'b1;
                        error_pixel <= 1'b0;
                        captured_lines_pixel <= 16'd0;
                        last_line_bytes_pixel <= 16'd0;
                        captured_words_pixel <= '0;
                        memory_write_address <= '0;
                        pack_count <= 3'd0;
                        pending_group_valid <= 1'b0;
                        pending_chunk <= 2'd0;
                        line_open <= 1'b0;
                        line_accepting <= 1'b0;
                        snapshot_state <= SNAP_WAIT_FRAME;
                    end
                end

                SNAP_WAIT_FRAME: begin
                    if (frame_start)
                        snapshot_state <= SNAP_CAPTURE;
                end

                SNAP_CAPTURE: begin
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
                                pending_group <= {
                                    pixel_data, pack_bytes
                                };
                                pending_group_valid <= 1'b1;
                                pending_chunk <= 2'd0;
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
                            snapshot_state <= SNAP_FLUSH;
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

                SNAP_FLUSH: begin
                    if (pending_group_valid && (pending_chunk == 3)) begin
                        busy_pixel <= 1'b0;
                        done_toggle_pixel <= arm_pixel_sync[1];
                        snapshot_state <= SNAP_IDLE;
                    end
                end

                default: snapshot_state <= SNAP_IDLE;
            endcase
        end
    end
endmodule
