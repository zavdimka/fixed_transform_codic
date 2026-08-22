module receiver_spi_osd_control #(
    parameter integer OSD_WORD_COUNT = 5760,
    parameter integer OSD_ADDRESS_WIDTH = 13
) (
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         spi_cs_n,
    input  logic                         spi_sck,
    input  logic                         spi_mosi,
    output logic                         spi_miso,

    input  logic                         pll2_lock,
    input  logic                         osd_clear_busy,
    input  logic                         osd_clear_done,
    output logic                         osd_clear_request,
    output logic                         osd_write_valid,
    input  logic                         osd_write_ready,
    output logic [OSD_ADDRESS_WIDTH-1:0] osd_write_address,
    output logic [39:0]                  osd_write_data,
    output logic                         osd_enable,
    output logic [23:0]                  osd_rgb,
    output logic                         osd_config_toggle,
    output logic [1:0]                   test_pattern_mode,
    output logic                         test_pattern_toggle,
    output logic                         link_drain_enable,

    input  logic [31:0]                  hdmi_frame_count,
    input  logic [12:0]                  link_fifo_level,
    input  logic                         link_clock_enabled,
    input  logic                         link_warning_level,
    input  logic                         link_overflow_error,
    input  logic                         link_framing_error,
    input  logic [31:0]                  link_byte_count,
    input  logic [31:0]                  link_transaction_count,
    input  logic [7:0]                   link_payload_xor,
    input  logic [5:0]                   led_auto_on,
    output logic [5:0]                   led_override_mask,
    output logic [5:0]                   led_manual_on,
    output logic                         command_error
);
    localparam logic [7:0] CMD_OSD_CONFIG = 8'h01;
    localparam logic [7:0] CMD_WRITE_LEDS = 8'h02;
    localparam logic [7:0] CMD_TEST_PATTERN = 8'h03;
    localparam logic [7:0] CMD_LINK_CONTROL = 8'h04;
    localparam logic [7:0] CMD_OSD_SET_ADDRESS = 8'h10;
    localparam logic [7:0] CMD_OSD_WRITE = 8'h11;
    localparam logic [7:0] CMD_OSD_CLEAR = 8'h12;
    localparam logic [7:0] CMD_READ_STATUS = 8'h80;
    localparam logic [7:0] CMD_READ_CONFIG = 8'h81;
    localparam logic [7:0] CMD_READ_TEST_PATTERN = 8'h82;
    localparam logic [7:0] CMD_READ_LEDS = 8'h83;
    localparam logic [7:0] CMD_READ_LINK_STATUS = 8'h90;
    localparam logic [OSD_ADDRESS_WIDTH-1:0] OSD_LAST_WORD =
        OSD_ADDRESS_WIDTH'(OSD_WORD_COUNT - 1);

    logic frame_start, frame_end, spi_active, rx_valid;
    logic [7:0] rx_data;
    logic [9:0] rx_index, tx_index;
    logic [7:0] tx_data;
    logic framing_error;
    logic [7:0] current_command;
    logic [7:0] osd_address_low;
    logic [2:0] osd_pack_count;
    logic [31:0] osd_pack_low;

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
                    10'd2: tx_data = 8'h12;
                    10'd3: tx_data = {
                        3'b000, command_error, osd_write_ready,
                        osd_clear_done, osd_clear_busy, pll2_lock
                    };
                    10'd4: tx_data = hdmi_frame_count[7:0];
                    10'd5: tx_data = hdmi_frame_count[15:8];
                    10'd6: tx_data = hdmi_frame_count[23:16];
                    10'd7: tx_data = hdmi_frame_count[31:24];
                    10'd8: tx_data = osd_write_address[7:0];
                    10'd9: tx_data = {3'd0, osd_write_address[12:8]};
                    default: tx_data = 8'd0;
                endcase
            end
            CMD_READ_CONFIG: begin
                case (tx_index)
                    10'd1: tx_data = {7'd0, osd_enable};
                    10'd2: tx_data = osd_rgb[23:16];
                    10'd3: tx_data = osd_rgb[15:8];
                    10'd4: tx_data = osd_rgb[7:0];
                    10'd5: tx_data = OSD_WORD_COUNT[7:0];
                    10'd6: tx_data = OSD_WORD_COUNT[15:8];
                    10'd7: tx_data = 8'd40;
                    default: tx_data = 8'd0;
                endcase
            end
            CMD_READ_TEST_PATTERN: begin
                if (tx_index == 1)
                    tx_data = {6'd0, test_pattern_mode};
            end
            CMD_READ_LEDS: begin
                case (tx_index)
                    10'd1: tx_data = {2'b00, led_auto_on};
                    10'd2: tx_data = {2'b00, led_override_mask};
                    10'd3: tx_data = {2'b00, led_manual_on};
                    10'd4: tx_data = {2'b00,
                        ((led_auto_on & ~led_override_mask)
                         | (led_manual_on & led_override_mask))};
                    default: tx_data = 8'd0;
                endcase
            end
            CMD_READ_LINK_STATUS: begin
                case (tx_index)
                    10'd1: tx_data = link_fifo_level[7:0];
                    10'd2: tx_data = {3'd0, link_fifo_level[12:8]};
                    10'd3: tx_data = {
                        2'd0, link_drain_enable, link_framing_error,
                        link_overflow_error, link_warning_level,
                        link_clock_enabled, (link_fifo_level != 0)
                    };
                    10'd4: tx_data = link_byte_count[7:0];
                    10'd5: tx_data = link_byte_count[15:8];
                    10'd6: tx_data = link_byte_count[23:16];
                    10'd7: tx_data = link_byte_count[31:24];
                    10'd8: tx_data = link_transaction_count[7:0];
                    10'd9: tx_data = link_transaction_count[15:8];
                    10'd10: tx_data = link_transaction_count[23:16];
                    10'd11: tx_data = link_transaction_count[31:24];
                    10'd12: tx_data = link_payload_xor;
                    default: tx_data = 8'd0;
                endcase
            end
            default: tx_data = 8'd0;
        endcase
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            current_command <= 8'd0;
            osd_address_low <= 8'd0;
            osd_pack_count <= 3'd0;
            osd_pack_low <= 32'd0;
            osd_write_address <= '0;
            osd_write_data <= 40'd0;
            osd_write_valid <= 1'b0;
            osd_clear_request <= 1'b0;
            osd_enable <= 1'b1;
            osd_rgb <= 24'hFFFFFF;
            osd_config_toggle <= 1'b0;
            test_pattern_mode <= 2'd0;
            test_pattern_toggle <= 1'b0;
            link_drain_enable <= 1'b1;
            led_override_mask <= 6'd0;
            led_manual_on <= 6'd0;
            command_error <= 1'b0;
        end else begin
            osd_write_valid <= 1'b0;
            osd_clear_request <= 1'b0;

            // Advance only after the framebuffer has sampled the registered
            // address/data/valid tuple on this edge.
            if (osd_write_valid && osd_write_ready
                && (osd_write_address != OSD_LAST_WORD))
                osd_write_address <= osd_write_address + 1'b1;

            if (frame_start)
                osd_pack_count <= 3'd0;

            if (frame_end && (current_command == CMD_OSD_WRITE)
                && (osd_pack_count != 0))
                command_error <= 1'b1;

            if (rx_valid) begin
                if (rx_index == 0) begin
                    current_command <= rx_data;
                    osd_pack_count <= 3'd0;
                    if (rx_data == CMD_OSD_CLEAR) begin
                        if (!osd_clear_busy)
                            osd_clear_request <= 1'b1;
                        else
                            command_error <= 1'b1;
                    end else if ((rx_data != CMD_OSD_CONFIG)
                                 && (rx_data != CMD_WRITE_LEDS)
                                 && (rx_data != CMD_TEST_PATTERN)
                                 && (rx_data != CMD_LINK_CONTROL)
                                 && (rx_data != CMD_OSD_SET_ADDRESS)
                                 && (rx_data != CMD_OSD_WRITE)
                                 && (rx_data != CMD_READ_STATUS)
                                 && (rx_data != CMD_READ_CONFIG)
                                 && (rx_data != CMD_READ_TEST_PATTERN)
                                 && (rx_data != CMD_READ_LEDS)
                                 && (rx_data != CMD_READ_LINK_STATUS)) begin
                        command_error <= 1'b1;
                    end
                end else begin
                    case (current_command)
                        CMD_OSD_CONFIG: begin
                            case (rx_index)
                                10'd1: osd_enable <= rx_data[0];
                                10'd2: osd_rgb[23:16] <= rx_data;
                                10'd3: osd_rgb[15:8] <= rx_data;
                                10'd4: begin
                                    osd_rgb[7:0] <= rx_data;
                                    osd_config_toggle <= ~osd_config_toggle;
                                end
                                default: begin end
                            endcase
                        end
                        CMD_WRITE_LEDS: begin
                            if (rx_index == 1)
                                led_override_mask <= rx_data[5:0];
                            else if (rx_index == 2)
                                led_manual_on <= rx_data[5:0];
                        end
                        CMD_TEST_PATTERN: begin
                            if (rx_index == 1) begin
                                test_pattern_mode <= rx_data[1:0];
                                test_pattern_toggle <= ~test_pattern_toggle;
                            end
                        end
                        CMD_LINK_CONTROL: begin
                            if (rx_index == 1)
                                link_drain_enable <= rx_data[0];
                        end
                        CMD_OSD_SET_ADDRESS: begin
                            if (rx_index == 1)
                                osd_address_low <= rx_data;
                            else if (rx_index == 2) begin
                                if ({rx_data[4:0], osd_address_low}
                                    <= OSD_LAST_WORD)
                                    osd_write_address <= {
                                        rx_data[4:0], osd_address_low
                                    };
                                else
                                    command_error <= 1'b1;
                            end
                        end
                        CMD_OSD_WRITE: begin
                            case (osd_pack_count)
                                3'd0: osd_pack_low[7:0] <= rx_data;
                                3'd1: osd_pack_low[15:8] <= rx_data;
                                3'd2: osd_pack_low[23:16] <= rx_data;
                                3'd3: osd_pack_low[31:24] <= rx_data;
                                default: begin
                                    if (osd_write_ready
                                        && (osd_write_address
                                            <= OSD_LAST_WORD)) begin
                                        osd_write_data <= {
                                            rx_data, osd_pack_low
                                        };
                                        osd_write_valid <= 1'b1;
                                    end else begin
                                        command_error <= 1'b1;
                                    end
                                end
                            endcase
                            if (osd_pack_count == 4)
                                osd_pack_count <= 3'd0;
                            else
                                osd_pack_count <= osd_pack_count + 1'b1;
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
    assign unused_spi_signals = frame_end ^ spi_active;
endmodule
