/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
module hevc_720p_spi_debug_top #(
    parameter integer FRAME_WIDTH = 1280,
    parameter integer FRAME_HEIGHT = 720,
    parameter integer CTU_COLUMNS = FRAME_WIDTH / 16,
    parameter integer CTU_ROWS = FRAME_HEIGHT / 16,
    parameter integer SLICE_CTU_ROWS = 5
) (
    input  logic       clk,
    input  logic       rst_n,

    input  logic       spi_cs_n,
    input  logic       spi_sck,
    input  logic       spi_mosi,
    output logic       spi_miso,

    output logic       nibble_valid,
    input  logic       nibble_ready,
    output logic [3:0] nibble_data,
    output logic       nibble_last,

    output logic [7:0] debug_status,
    output logic [6:0] current_ctu_x,
    output logic [5:0] current_ctu_y,
    output logic [31:0] nal_byte_count,
    output logic       debug_error
);
    localparam logic [7:0] CMD_CONFIG = 8'h01;
    localparam logic [7:0] CMD_START_SLICE = 8'h02;
    localparam logic [7:0] CMD_LOAD_CTU = 8'h10;
    localparam logic [7:0] CMD_RUN_CTU = 8'h11;
    localparam logic [7:0] CMD_SOFT_RESET = 8'h20;
    localparam logic [7:0] CMD_CLEAR_ERRORS = 8'h21;
    localparam logic [7:0] CMD_READ_STATUS = 8'h80;
    localparam logic [7:0] CMD_READ_SIGNATURES = 8'h81;

    logic spi_frame_start;
    logic spi_frame_end;
    logic spi_active;
    logic spi_rx_valid;
    logic [7:0] spi_rx_data;
    logic [9:0] spi_rx_index;
    logic [9:0] spi_tx_index;
    logic [7:0] spi_tx_data;
    logic spi_framing_error;

    logic [7:0] current_command;
    logic [9:0] command_payload_count;
    logic [15:0] load_crc;
    logic [15:0] received_crc;
    logic length_error;
    logic crc_error;
    logic command_error;
    logic soft_reset_pulse;
    logic codec_rst_n;

    logic [5:0] config_slice_row;
    logic [5:0] config_qp;
    logic [1:0] config_quality;
    logic config_no_output_of_prior_pics;
    logic slice_start_pending;
    logic slice_started;
    logic run_pending;

    logic loader_load_clear;
    logic loader_load_write_valid;
    logic [7:0] loader_load_write_data;
    logic loader_load_commit;
    logic loader_loaded;
    logic [8:0] loader_load_count;
    logic loader_load_error;
    logic loader_run_ready;
    logic loader_run_done;
    logic loader_busy;
    logic loader_ctu_start_valid;
    logic loader_ctu_start_ready;
    logic loader_y_valid;
    logic loader_y_ready;
    logic [7:0] loader_y_pixel;
    logic loader_cb_valid;
    logic loader_cb_ready;
    logic [7:0] loader_cb_pixel;
    logic loader_cr_valid;
    logic loader_cr_ready;
    logic [7:0] loader_cr_pixel;

    logic core_start_ready;
    logic core_y_recon_valid;
    logic [7:0] core_y_reconstructed;
    logic [3:0] core_y_recon_x;
    logic [3:0] core_y_recon_y;
    logic core_y_recon_block_last;
    logic core_chroma_recon_valid;
    logic [1:0] core_chroma_recon_plane;
    logic [7:0] core_chroma_reconstructed;
    logic [2:0] core_chroma_recon_x;
    logic [2:0] core_chroma_recon_y;
    logic core_chroma_recon_block_last;
    logic core_nal_valid;
    logic core_nal_ready;
    logic [7:0] core_nal_byte;
    logic core_nal_last;
    logic core_luma_mode_dc;
    logic core_luma_tu_done;
    logic core_chroma_tu_done;
    logic core_ctu_done;
    logic core_done;
    logic core_parameter_error;
    logic core_protocol_error;
    logic core_busy;
    logic nibble_input_ready;

    logic [15:0] y_recon_crc;
    logic [15:0] chroma_recon_crc;
    logic [15:0] nal_crc;
    logic [15:0] accepted_load_crc;
    logic [15:0] y_recon_count;
    logic [15:0] chroma_recon_count;

    wire core_start_fire = slice_start_pending && core_start_ready;
    wire loader_run_fire = run_pending && loader_run_ready;
    wire nal_fire = core_nal_valid && core_nal_ready;

    function automatic logic [15:0] crc16_byte(
        input logic [15:0] crc,
        input logic [7:0] data
    );
        logic [15:0] value;
        integer bit_index;
        begin
            value = crc ^ {data, 8'd0};
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1)
                value = value[15] ?
                    ((value << 1) ^ 16'h1021) : (value << 1);
            crc16_byte = value;
        end
    endfunction

    assign codec_rst_n = rst_n && !soft_reset_pulse;
    assign core_nal_ready = nibble_input_ready;
    assign debug_status = {
        debug_error,
        core_parameter_error,
        core_protocol_error,
        run_pending,
        slice_start_pending,
        core_busy,
        loader_busy,
        loader_loaded
    };
    assign debug_error = spi_framing_error || length_error || crc_error ||
        command_error || loader_load_error || core_parameter_error ||
        core_protocol_error;

    always_comb begin
        spi_tx_data = 8'd0;
        case (current_command)
            CMD_READ_STATUS: begin
                case (spi_tx_index)
                    10'd1: spi_tx_data = debug_status;
                    10'd2: spi_tx_data = 8'h01;
                    10'd3: spi_tx_data = {1'b0, current_ctu_x};
                    10'd4: spi_tx_data = {2'b00, current_ctu_y};
                    10'd5: spi_tx_data = loader_load_count[7:0];
                    10'd6: spi_tx_data = {7'd0, loader_load_count[8]};
                    10'd7: spi_tx_data = {
                        1'b0, core_parameter_error, core_protocol_error,
                        loader_load_error, command_error, crc_error,
                        length_error, spi_framing_error
                    };
                    default: spi_tx_data = 8'd0;
                endcase
            end
            CMD_READ_SIGNATURES: begin
                case (spi_tx_index)
                    10'd1: spi_tx_data = nal_byte_count[7:0];
                    10'd2: spi_tx_data = nal_byte_count[15:8];
                    10'd3: spi_tx_data = nal_byte_count[23:16];
                    10'd4: spi_tx_data = nal_byte_count[31:24];
                    10'd5: spi_tx_data = accepted_load_crc[15:8];
                    10'd6: spi_tx_data = accepted_load_crc[7:0];
                    10'd7: spi_tx_data = y_recon_crc[15:8];
                    10'd8: spi_tx_data = y_recon_crc[7:0];
                    10'd9: spi_tx_data = chroma_recon_crc[15:8];
                    10'd10: spi_tx_data = chroma_recon_crc[7:0];
                    10'd11: spi_tx_data = nal_crc[15:8];
                    10'd12: spi_tx_data = nal_crc[7:0];
                    10'd13: spi_tx_data = y_recon_count[7:0];
                    10'd14: spi_tx_data = y_recon_count[15:8];
                    10'd15: spi_tx_data = chroma_recon_count[7:0];
                    10'd16: spi_tx_data = chroma_recon_count[15:8];
                    default: spi_tx_data = 8'd0;
                endcase
            end
            default: spi_tx_data = 8'd0;
        endcase
    end

    spi_debug_slave spi_slave (
        .clk(clk),
        .rst_n(rst_n),
        .spi_cs_n(spi_cs_n),
        .spi_sck(spi_sck),
        .spi_mosi(spi_mosi),
        .spi_miso(spi_miso),
        .frame_start(spi_frame_start),
        .frame_end(spi_frame_end),
        .active(spi_active),
        .rx_valid(spi_rx_valid),
        .rx_data(spi_rx_data),
        .rx_index(spi_rx_index),
        .tx_index(spi_tx_index),
        .tx_data(spi_tx_data),
        .framing_error(spi_framing_error)
    );

    hevc_debug_ctu_loader ctu_loader (
        .clk(clk),
        .rst_n(codec_rst_n),
        .load_clear(loader_load_clear),
        .load_write_valid(loader_load_write_valid),
        .load_write_data(loader_load_write_data),
        .load_commit(loader_load_commit),
        .loaded(loader_loaded),
        .load_count(loader_load_count),
        .load_error(loader_load_error),
        .run_valid(run_pending),
        .run_ready(loader_run_ready),
        .run_done(loader_run_done),
        .busy(loader_busy),
        .ctu_start_valid(loader_ctu_start_valid),
        .ctu_start_ready(loader_ctu_start_ready),
        .y_valid(loader_y_valid),
        .y_ready(loader_y_ready),
        .y_pixel(loader_y_pixel),
        .cb_valid(loader_cb_valid),
        .cb_ready(loader_cb_ready),
        .cb_pixel(loader_cb_pixel),
        .cr_valid(loader_cr_valid),
        .cr_ready(loader_cr_ready),
        .cr_pixel(loader_cr_pixel),
        .ctu_done(core_ctu_done)
    );

    byte_to_nibble_last output_nibbles (
        .clk(clk),
        .rst_n(codec_rst_n),
        .s_valid(core_nal_valid),
        .s_ready(nibble_input_ready),
        .s_data(core_nal_byte),
        .s_last(core_nal_last),
        .m_valid(nibble_valid),
        .m_ready(nibble_ready),
        .m_data(nibble_data),
        .m_last(nibble_last)
    );

    hevc_yuv_pixel_ctu16_idr_nal #(
        .FRAME_WIDTH(FRAME_WIDTH),
        .FRAME_HEIGHT(FRAME_HEIGHT),
        .CTU_COLUMNS(CTU_COLUMNS),
        .CTU_ROWS(CTU_ROWS),
        .SLICE_CTU_ROWS(SLICE_CTU_ROWS)
    ) codec (
        .clk(clk),
        .rst_n(codec_rst_n),
        .start_valid(slice_start_pending),
        .start_ready(core_start_ready),
        .slice_row(config_slice_row),
        .qp(config_qp),
        .no_output_of_prior_pics(config_no_output_of_prior_pics),
        .ctu_start_valid(loader_ctu_start_valid),
        .ctu_start_ready(loader_ctu_start_ready),
        .quality(config_quality),
        .y_valid(loader_y_valid),
        .y_ready(loader_y_ready),
        .y_pixel(loader_y_pixel),
        .cb_valid(loader_cb_valid),
        .cb_ready(loader_cb_ready),
        .cb_pixel(loader_cb_pixel),
        .cr_valid(loader_cr_valid),
        .cr_ready(loader_cr_ready),
        .cr_pixel(loader_cr_pixel),
        .y_recon_valid(core_y_recon_valid),
        .y_recon_ready(1'b1),
        .y_reconstructed(core_y_reconstructed),
        .y_recon_x(core_y_recon_x),
        .y_recon_y(core_y_recon_y),
        .y_recon_block_last(core_y_recon_block_last),
        .chroma_recon_valid(core_chroma_recon_valid),
        .chroma_recon_ready(1'b1),
        .chroma_recon_plane(core_chroma_recon_plane),
        .chroma_reconstructed(core_chroma_reconstructed),
        .chroma_recon_x(core_chroma_recon_x),
        .chroma_recon_y(core_chroma_recon_y),
        .chroma_recon_block_last(core_chroma_recon_block_last),
        .nal_valid(core_nal_valid),
        .nal_ready(core_nal_ready),
        .nal_byte(core_nal_byte),
        .nal_last(core_nal_last),
        .current_ctu_x(current_ctu_x),
        .current_ctu_y(current_ctu_y),
        .current_luma_mode_dc(core_luma_mode_dc),
        .luma_tu_done(core_luma_tu_done),
        .chroma_tu_done(core_chroma_tu_done),
        .ctu_done(core_ctu_done),
        .done(core_done),
        .parameter_error(core_parameter_error),
        .protocol_error(core_protocol_error),
        .busy(core_busy)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            current_command <= 8'd0;
            command_payload_count <= 10'd0;
            load_crc <= 16'hffff;
            received_crc <= 16'd0;
            accepted_load_crc <= 16'd0;
            length_error <= 1'b0;
            crc_error <= 1'b0;
            command_error <= 1'b0;
            soft_reset_pulse <= 1'b0;
            config_slice_row <= 6'd0;
            config_qp <= 6'd34;
            config_quality <= 2'd1;
            config_no_output_of_prior_pics <= 1'b0;
            slice_start_pending <= 1'b0;
            slice_started <= 1'b0;
            run_pending <= 1'b0;
            loader_load_clear <= 1'b0;
            loader_load_write_valid <= 1'b0;
            loader_load_write_data <= 8'd0;
            loader_load_commit <= 1'b0;
            nal_byte_count <= 32'd0;
            y_recon_crc <= 16'hffff;
            chroma_recon_crc <= 16'hffff;
            nal_crc <= 16'hffff;
            y_recon_count <= 16'd0;
            chroma_recon_count <= 16'd0;
        end else begin
            soft_reset_pulse <= 1'b0;
            loader_load_clear <= 1'b0;
            loader_load_write_valid <= 1'b0;
            loader_load_commit <= 1'b0;

            if (spi_frame_start) begin
                current_command <= 8'd0;
                command_payload_count <= 10'd0;
            end

            if (spi_rx_valid) begin
                if (spi_rx_index == 10'd0) begin
                    current_command <= spi_rx_data;
                    command_payload_count <= 10'd0;
                    if (spi_rx_data == CMD_LOAD_CTU) begin
                        if (loader_busy)
                            command_error <= 1'b1;
                        else
                            loader_load_clear <= 1'b1;
                        load_crc <= 16'hffff;
                        received_crc <= 16'd0;
                    end
                end else begin
                    command_payload_count <= command_payload_count + 1'b1;
                    case (current_command)
                        CMD_CONFIG: begin
                            case (command_payload_count)
                                10'd0: config_slice_row <= spi_rx_data[5:0];
                                10'd1: config_qp <= spi_rx_data[5:0];
                                10'd2: begin
                                    config_quality <= spi_rx_data[1:0];
                                    config_no_output_of_prior_pics <=
                                        spi_rx_data[7];
                                end
                                default: command_error <= 1'b1;
                            endcase
                        end
                        CMD_LOAD_CTU: begin
                            if (command_payload_count < 10'd384) begin
                                loader_load_write_valid <= 1'b1;
                                loader_load_write_data <= spi_rx_data;
                                load_crc <= crc16_byte(load_crc, spi_rx_data);
                            end else if (command_payload_count == 10'd384) begin
                                received_crc[15:8] <= spi_rx_data;
                            end else if (command_payload_count == 10'd385) begin
                                received_crc[7:0] <= spi_rx_data;
                            end else begin
                                command_error <= 1'b1;
                            end
                        end
                        CMD_READ_STATUS, CMD_READ_SIGNATURES: begin
                            // Dummy MOSI bytes clock the selected response out.
                        end
                        default: command_error <= 1'b1;
                    endcase
                end
            end

            if (spi_frame_end) begin
                case (current_command)
                    CMD_CONFIG: begin
                        if (command_payload_count != 10'd3)
                            length_error <= 1'b1;
                    end
                    CMD_START_SLICE: begin
                        if (command_payload_count == 10'd0)
                            slice_start_pending <= 1'b1;
                        else
                            length_error <= 1'b1;
                    end
                    CMD_LOAD_CTU: begin
                        if (command_payload_count != 10'd386) begin
                            length_error <= 1'b1;
                        end else if (load_crc != received_crc) begin
                            crc_error <= 1'b1;
                        end else begin
                            loader_load_commit <= 1'b1;
                            accepted_load_crc <= load_crc;
                        end
                    end
                    CMD_RUN_CTU: begin
                        if (command_payload_count != 10'd0)
                            length_error <= 1'b1;
                        else if (!loader_loaded)
                            command_error <= 1'b1;
                        else
                            run_pending <= 1'b1;
                    end
                    CMD_SOFT_RESET: begin
                        if (command_payload_count == 10'd0)
                            soft_reset_pulse <= 1'b1;
                        else
                            length_error <= 1'b1;
                    end
                    CMD_CLEAR_ERRORS: begin
                        if (command_payload_count == 10'd0) begin
                            length_error <= 1'b0;
                            crc_error <= 1'b0;
                            command_error <= 1'b0;
                        end else begin
                            length_error <= 1'b1;
                        end
                    end
                    CMD_READ_STATUS, CMD_READ_SIGNATURES: begin
                        // Any number of dummy bytes is valid.
                    end
                    default: command_error <= 1'b1;
                endcase
            end

            if (core_start_fire) begin
                slice_start_pending <= 1'b0;
                slice_started <= 1'b1;
                nal_byte_count <= 32'd0;
                y_recon_crc <= 16'hffff;
                chroma_recon_crc <= 16'hffff;
                nal_crc <= 16'hffff;
                y_recon_count <= 16'd0;
                chroma_recon_count <= 16'd0;
            end
            if (loader_run_fire)
                run_pending <= 1'b0;

            if (core_y_recon_valid) begin
                y_recon_crc <= crc16_byte(y_recon_crc, core_y_reconstructed);
                y_recon_count <= y_recon_count + 1'b1;
            end
            if (core_chroma_recon_valid) begin
                chroma_recon_crc <= crc16_byte(
                    chroma_recon_crc, core_chroma_reconstructed);
                chroma_recon_count <= chroma_recon_count + 1'b1;
            end
            if (nal_fire) begin
                nal_crc <= crc16_byte(nal_crc, core_nal_byte);
                nal_byte_count <= nal_byte_count + 1'b1;
            end

            if (soft_reset_pulse) begin
                slice_start_pending <= 1'b0;
                slice_started <= 1'b0;
                run_pending <= 1'b0;
                length_error <= 1'b0;
                crc_error <= 1'b0;
                command_error <= 1'b0;
                nal_byte_count <= 32'd0;
                y_recon_crc <= 16'hffff;
                chroma_recon_crc <= 16'hffff;
                nal_crc <= 16'hffff;
                y_recon_count <= 16'd0;
                chroma_recon_count <= 16'd0;
            end
        end
    end

    logic unused_status;
    assign unused_status = ^{spi_active, slice_started, loader_run_done,
        core_y_recon_x, core_y_recon_y, core_y_recon_block_last,
        core_chroma_recon_plane, core_chroma_recon_x, core_chroma_recon_y,
        core_chroma_recon_block_last, core_luma_mode_dc,
        core_luma_tu_done, core_chroma_tu_done, core_done};
endmodule
/* verilator lint_on WIDTHTRUNC */
/* verilator lint_on WIDTHEXPAND */
