module custom_spi_debug_control #(
    parameter integer SNAPSHOT_ADDRESS_WIDTH = 14
) (
    input  logic                              clk,
    input  logic                              rst_n,
    input  logic                              spi_cs_n,
    input  logic                              spi_sck,
    input  logic                              spi_mosi,
    output logic                              spi_miso,

    input  logic                              codec_busy,
    input  logic                              codec_error,
    input  logic                              coefficient_saturated,
    input  logic                              packet_overflow,
    input  logic                              packet_active,
    input  logic                              packet_layer,
    input  logic [15:0]                       packet_byte_length,
    input  logic [31:0]                       packet_count,
    input  logic                              quality24,
    input  logic [2:0]                        ctu_index,

    output logic [15:0]                       gap_cycles,
    output logic [1:0]                        source_mode,
    output logic                              capture_arm,
    output logic                              vsync_active_high,
    output logic                              href_active_high,
    input  logic                              capture_busy,
    input  logic                              capture_done,
    input  logic                              capture_error,
    input  logic [15:0]                       captured_lines,
    input  logic [15:0]                       last_line_bytes,
    input  logic [SNAPSHOT_ADDRESS_WIDTH:0]   captured_words,
    output logic                              snapshot_read_request,
    output logic [SNAPSHOT_ADDRESS_WIDTH-1:0] snapshot_read_address,
    input  logic                              snapshot_read_valid,
    input  logic [39:0]                       snapshot_read_word,
    output logic                              command_error
);
    localparam logic [7:0] CMD_CONFIG = 8'h01;
    localparam logic [7:0] CMD_ARM_CAPTURE = 8'h20;
    localparam logic [7:0] CMD_SET_SNAPSHOT_ADDRESS = 8'h22;
    localparam logic [7:0] CMD_READ_STATUS = 8'h80;
    localparam logic [7:0] CMD_READ_CAPTURE = 8'h81;
    localparam logic [7:0] CMD_READ_SNAPSHOT_WORD = 8'h82;

    logic frame_start, frame_end, spi_active, rx_valid;
    logic [7:0] rx_data;
    logic [9:0] rx_index, tx_index;
    logic [7:0] tx_data;
    logic framing_error;
    logic [7:0] current_command;
    logic [7:0] snapshot_address_low;
    logic snapshot_request_pending;
    logic [39:0] snapshot_word_cache;
    logic snapshot_cache_valid;

    spi_debug_slave spi_slave (
        .clk(clk), .rst_n(rst_n),
        .spi_cs_n(spi_cs_n), .spi_sck(spi_sck),
        .spi_mosi(spi_mosi), .spi_miso(spi_miso),
        .frame_start(frame_start), .frame_end(frame_end),
        .active(spi_active), .rx_valid(rx_valid), .rx_data(rx_data),
        .rx_index(rx_index), .tx_index(tx_index), .tx_data(tx_data),
        .framing_error(framing_error)
    );

    always_comb begin
        tx_data = 8'd0;
        case (current_command)
            CMD_READ_STATUS: begin
                case (tx_index)
                    10'd1: tx_data = 8'hC5;
                    10'd2: tx_data = 8'h01;
                    10'd3: tx_data = {
                        codec_error, coefficient_saturated,
                        packet_overflow, command_error,
                        capture_error, capture_done, capture_busy,
                        codec_busy
                    };
                    10'd4: tx_data = {
                        source_mode, quality24, ctu_index,
                        packet_layer, packet_active
                    };
                    10'd5: tx_data = gap_cycles[7:0];
                    10'd6: tx_data = gap_cycles[15:8];
                    10'd7: tx_data = packet_byte_length[7:0];
                    10'd8: tx_data = packet_byte_length[15:8];
                    10'd9: tx_data = packet_count[7:0];
                    10'd10: tx_data = packet_count[15:8];
                    10'd11: tx_data = packet_count[23:16];
                    10'd12: tx_data = packet_count[31:24];
                    default: tx_data = 8'd0;
                endcase
            end
            CMD_READ_CAPTURE: begin
                case (tx_index)
                    10'd1: tx_data = captured_lines[7:0];
                    10'd2: tx_data = captured_lines[15:8];
                    10'd3: tx_data = last_line_bytes[7:0];
                    10'd4: tx_data = last_line_bytes[15:8];
                    10'd5: tx_data = captured_words[7:0];
                    10'd6: tx_data = {1'b0, captured_words[14:8]};
                    10'd7: tx_data = {7'd0, snapshot_cache_valid};
                    default: tx_data = 8'd0;
                endcase
            end
            CMD_READ_SNAPSHOT_WORD: begin
                case (tx_index)
                    10'd1: tx_data = snapshot_word_cache[7:0];
                    10'd2: tx_data = snapshot_word_cache[15:8];
                    10'd3: tx_data = snapshot_word_cache[23:16];
                    10'd4: tx_data = snapshot_word_cache[31:24];
                    10'd5: tx_data = snapshot_word_cache[39:32];
                    10'd6: tx_data = {7'd0, snapshot_cache_valid};
                    default: tx_data = 8'd0;
                endcase
            end
            default: tx_data = 8'd0;
        endcase
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            current_command <= 8'd0;
            gap_cycles <= 16'd32;
            source_mode <= 2'd0;
            capture_arm <= 1'b0;
            vsync_active_high <= 1'b1;
            href_active_high <= 1'b1;
            snapshot_address_low <= 8'd0;
            snapshot_read_address <= '0;
            snapshot_read_request <= 1'b0;
            snapshot_request_pending <= 1'b0;
            snapshot_word_cache <= 40'd0;
            snapshot_cache_valid <= 1'b0;
            command_error <= 1'b0;
        end else begin
            capture_arm <= 1'b0;
            snapshot_read_request <= 1'b0;

            if (snapshot_request_pending) begin
                snapshot_read_request <= 1'b1;
                snapshot_request_pending <= 1'b0;
                snapshot_cache_valid <= 1'b0;
            end
            if (snapshot_read_valid) begin
                snapshot_word_cache <= snapshot_read_word;
                snapshot_cache_valid <= 1'b1;
            end

            if (frame_end && (current_command == CMD_READ_SNAPSHOT_WORD)) begin
                snapshot_read_address <= snapshot_read_address + 1'b1;
                snapshot_request_pending <= 1'b1;
            end

            if (rx_valid) begin
                if (rx_index == 0) begin
                    current_command <= rx_data;
                    if (rx_data == CMD_ARM_CAPTURE)
                        capture_arm <= 1'b1;
                    else if ((rx_data != CMD_CONFIG)
                             && (rx_data != CMD_SET_SNAPSHOT_ADDRESS)
                             && (rx_data != CMD_READ_STATUS)
                             && (rx_data != CMD_READ_CAPTURE)
                             && (rx_data != CMD_READ_SNAPSHOT_WORD))
                        command_error <= 1'b1;
                end else begin
                    case (current_command)
                        CMD_CONFIG: begin
                            if (rx_index == 1)
                                gap_cycles[7:0] <= rx_data;
                            else if (rx_index == 2)
                                gap_cycles[15:8] <= rx_data;
                            else if (rx_index == 3) begin
                                vsync_active_high <= rx_data[0];
                                href_active_high <= rx_data[1];
                            end else if (rx_index == 4)
                                source_mode <= rx_data[1:0];
                        end
                        CMD_SET_SNAPSHOT_ADDRESS: begin
                            if (rx_index == 1)
                                snapshot_address_low <= rx_data;
                            else if (rx_index == 2) begin
                                snapshot_read_address <= {
                                    rx_data[SNAPSHOT_ADDRESS_WIDTH-9:0],
                                    snapshot_address_low
                                };
                                snapshot_request_pending <= 1'b1;
                            end
                        end
                        default: begin end
                    endcase
                end
            end

            if (framing_error)
                command_error <= 1'b1;
        end
    end

    logic unused_spi_signals;
    assign unused_spi_signals = frame_start ^ frame_end ^ spi_active;
endmodule
