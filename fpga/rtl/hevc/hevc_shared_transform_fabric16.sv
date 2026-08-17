module hevc_shared_transform_fabric16 (
    input  logic clk,
    input  logic rst_n,
    input  logic command_valid,
    output logic command_ready,
    input  logic command_pair8,
    input  logic command_inverse,
    input  logic s_valid,
    output logic s_ready,
    input  logic signed [15:0] s_data,
    output logic m_valid,
    input  logic m_ready,
    output logic signed [15:0] m_data,
    output logic m_plane,
    output logic [3:0] m_x,
    output logic [3:0] m_y,
    output logic m_block_last,
    output logic m_pair_last,
    output logic done,
    output logic busy
);
    logic active_pair8, input_plane, output_plane;
    logic [5:0] input_count;

    logic luma_command_ready, luma_s_ready, luma_m_valid, luma_done;
    logic luma_busy, luma_protocol_error;
    logic signed [15:0] luma_m_data;
    logic [3:0] luma_m_x, luma_m_y;
    logic luma_m_last;
    logic luma_input_read_enable, luma_intermediate_read_enable;
    logic [3:0] luma_input_read_address, luma_intermediate_read_address;
    logic [15:0] luma_input_write_enable;
    logic [63:0] luma_input_write_address;
    logic signed [255:0] luma_input_write_data;
    logic signed [255:0] luma_input_read_data;
    logic [15:0] luma_intermediate_write_enable;
    logic [63:0] luma_intermediate_write_address;
    logic signed [255:0] luma_intermediate_write_data;
    logic signed [255:0] luma_intermediate_read_data;
    logic signed [255:0] luma_mac_samples;
    logic signed [127:0] luma_mac_coefficients;
    logic signed [383:0] luma_mac_products;
    logic luma_mac_enable;
    logic luma_coefficient_read_enable;
    logic [5:0] luma_coefficient_read_address;

    logic lane_command_ready [0:1];
    logic lane_s_ready [0:1], lane_m_valid [0:1], lane_m_ready [0:1];
    logic lane_done [0:1], lane_busy [0:1], lane_m_last [0:1];
    logic signed [15:0] lane_m_data [0:1];
    logic [2:0] lane_m_x [0:1], lane_m_y [0:1];
    logic lane_input_read_enable [0:1];
    logic [2:0] lane_input_read_address [0:1];
    logic [7:0] lane_input_write_enable [0:1];
    logic [23:0] lane_input_write_address [0:1];
    logic signed [127:0] lane_input_write_data [0:1];
    logic signed [127:0] lane_input_read_data [0:1];
    logic lane_intermediate_read_enable [0:1];
    logic [2:0] lane_intermediate_read_address [0:1];
    logic [7:0] lane_intermediate_write_enable [0:1];
    logic [23:0] lane_intermediate_write_address [0:1];
    logic signed [127:0] lane_intermediate_write_data [0:1];
    logic signed [127:0] lane_intermediate_read_data [0:1];
    logic signed [127:0] lane_mac_samples [0:1];
    logic signed [63:0] lane_mac_coefficients [0:1];
    logic signed [191:0] lane_mac_products [0:1];
    logic lane_mac_enable [0:1];
    logic lane_coefficient_read_enable [0:1];
    logic [5:0] lane_coefficient_read_address [0:1];

    logic signed [127:0] coefficient_rom_data [0:1];

    logic bank_input_read_enable [0:15];
    logic [3:0] bank_input_read_address [0:15];
    logic bank_input_write_enable [0:15];
    logic [3:0] bank_input_write_address [0:15];
    logic signed [15:0] bank_input_write_data [0:15];
    logic signed [15:0] bank_input_read_data [0:15];
    logic bank_intermediate_read_enable [0:15];
    logic [3:0] bank_intermediate_read_address [0:15];
    logic bank_intermediate_write_enable [0:15];
    logic [3:0] bank_intermediate_write_address [0:15];
    logic signed [15:0] bank_intermediate_write_data [0:15];
    logic signed [15:0] bank_intermediate_read_data [0:15];

    logic signed [127:0] mac_samples_a, mac_samples_b;
    logic signed [63:0] mac_coefficients_a, mac_coefficients_b;
    logic signed [191:0] mac_products_a, mac_products_b;
    integer control_bank;

    wire command_fire = command_valid && command_ready;
    wire input_fire = s_valid && s_ready;
    wire output_fire = m_valid && m_ready;

    assign command_ready = command_pair8 ?
        (lane_command_ready[0] && lane_command_ready[1]) :
        luma_command_ready;
    assign s_ready = active_pair8 ? lane_s_ready[input_plane] : luma_s_ready;
    assign lane_m_ready[0] = active_pair8 && !output_plane && m_ready;
    assign lane_m_ready[1] = active_pair8 && output_plane && m_ready;
    assign m_valid = active_pair8 ? lane_m_valid[output_plane] : luma_m_valid;
    assign m_data = active_pair8 ? lane_m_data[output_plane] : luma_m_data;
    assign m_plane = active_pair8 ? output_plane : 1'b0;
    assign m_x = active_pair8 ? {1'b0, lane_m_x[output_plane]} : luma_m_x;
    assign m_y = active_pair8 ? {1'b0, lane_m_y[output_plane]} : luma_m_y;
    assign m_block_last = active_pair8 ? lane_m_last[output_plane] : luma_m_last;
    assign m_pair_last = active_pair8 ? (output_plane && lane_m_last[1]) :
        luma_m_last;
    assign busy = active_pair8 ? (lane_busy[0] || lane_busy[1]) : luma_busy;

    assign mac_samples_a = active_pair8 ? lane_mac_samples[0] :
        luma_mac_samples[127:0];
    assign mac_samples_b = active_pair8 ? lane_mac_samples[1] :
        luma_mac_samples[255:128];
    assign mac_coefficients_a = active_pair8 ? lane_mac_coefficients[0] :
        luma_mac_coefficients[63:0];
    assign mac_coefficients_b = active_pair8 ? lane_mac_coefficients[1] :
        luma_mac_coefficients[127:64];
    assign lane_mac_products[0] = mac_products_a;
    assign lane_mac_products[1] = mac_products_b;
    assign luma_mac_products = {mac_products_b, mac_products_a};

    hevc_transform_coefficient_rom coefficient_rom0 (
        .clk,
        .read_enable(active_pair8 ? lane_coefficient_read_enable[0] :
            luma_coefficient_read_enable),
        .read_address(active_pair8 ? lane_coefficient_read_address[0] :
            luma_coefficient_read_address),
        .read_data(coefficient_rom_data[0]));

    hevc_transform_coefficient_rom coefficient_rom1 (
        .clk,
        .read_enable(active_pair8 && lane_coefficient_read_enable[1]),
        .read_address(lane_coefficient_read_address[1]),
        .read_data(coefficient_rom_data[1]));

    hevc_transform_mac8x2 mac (
        .clk,
        .enable_a(active_pair8 ? lane_mac_enable[0] : luma_mac_enable),
        .samples_a(mac_samples_a), .coefficients_a(mac_coefficients_a),
        .products_a(mac_products_a),
        .enable_b(active_pair8 ? lane_mac_enable[1] : luma_mac_enable),
        .samples_b(mac_samples_b),
        .coefficients_b(mac_coefficients_b), .products_b(mac_products_b));

    hevc_shared_transform_core #(
        .STREAM_FORWARD_PASS1(1'b1), .STREAM_INVERSE_PASS1(1'b1),
        .EXTERNAL_DATAPATH(1'b1)) luma_controller (
        .clk, .rst_n,
        .command_valid(command_valid && !command_pair8),
        .command_ready(luma_command_ready), .command_size8(1'b0),
        .command_inverse, .s_valid(s_valid && !active_pair8),
        .s_ready(luma_s_ready), .s_data, .m_valid(luma_m_valid),
        .m_ready(!active_pair8 && m_ready), .m_data(luma_m_data),
        .m_x(luma_m_x), .m_y(luma_m_y), .m_block_last(luma_m_last),
        .done(luma_done), .protocol_error(luma_protocol_error),
        .busy(luma_busy),
        .external_input_read_enable(luma_input_read_enable),
        .external_input_read_address(luma_input_read_address),
        .external_input_write_enable(luma_input_write_enable),
        .external_input_write_address(luma_input_write_address),
        .external_input_write_data(luma_input_write_data),
        .external_input_read_data(luma_input_read_data),
        .external_intermediate_read_enable(luma_intermediate_read_enable),
        .external_intermediate_read_address(luma_intermediate_read_address),
        .external_intermediate_write_enable(luma_intermediate_write_enable),
        .external_intermediate_write_address(luma_intermediate_write_address),
        .external_intermediate_write_data(luma_intermediate_write_data),
        .external_intermediate_read_data(luma_intermediate_read_data),
        .external_mac_samples(luma_mac_samples),
        .external_coefficient_read_enable(luma_coefficient_read_enable),
        .external_coefficient_read_address(luma_coefficient_read_address),
        .external_coefficient_read_data(coefficient_rom_data[0]),
        .external_mac_coefficients(luma_mac_coefficients),
        .external_mac_enable(luma_mac_enable),
        .external_mac_products(luma_mac_products));

    genvar lane;
    generate
        for (lane = 0; lane < 2; lane = lane + 1) begin : lane_controllers
            hevc_stream_transform_lane8 #(.EXTERNAL_DATAPATH(1'b1)) controller (
                .clk, .rst_n,
                .command_valid(command_valid && command_pair8 &&
                    lane_command_ready[1-lane]),
                .command_ready(lane_command_ready[lane]), .command_inverse,
                .s_valid(s_valid && active_pair8 && (input_plane == lane)),
                .s_ready(lane_s_ready[lane]), .s_data,
                .m_valid(lane_m_valid[lane]), .m_ready(lane_m_ready[lane]),
                .m_data(lane_m_data[lane]), .m_x(lane_m_x[lane]),
                .m_y(lane_m_y[lane]), .m_block_last(lane_m_last[lane]),
                .done(lane_done[lane]), .busy(lane_busy[lane]),
                .mac_samples(lane_mac_samples[lane]),
                .mac_coefficients(lane_mac_coefficients[lane]),
                .mac_enable(lane_mac_enable[lane]),
                .mac_products(lane_mac_products[lane]),
                .external_input_read_enable(lane_input_read_enable[lane]),
                .external_input_read_address(lane_input_read_address[lane]),
                .external_input_write_enable(lane_input_write_enable[lane]),
                .external_input_write_address(lane_input_write_address[lane]),
                .external_input_write_data(lane_input_write_data[lane]),
                .external_input_read_data(lane_input_read_data[lane]),
                .external_intermediate_read_enable(
                    lane_intermediate_read_enable[lane]),
                .external_intermediate_read_address(
                    lane_intermediate_read_address[lane]),
                .external_intermediate_write_enable(
                    lane_intermediate_write_enable[lane]),
                .external_intermediate_write_address(
                    lane_intermediate_write_address[lane]),
                .external_intermediate_write_data(
                    lane_intermediate_write_data[lane]),
                .external_intermediate_read_data(
                    lane_intermediate_read_data[lane]),
                .external_coefficient_read_enable(
                    lane_coefficient_read_enable[lane]),
                .external_coefficient_read_address(
                    lane_coefficient_read_address[lane]),
                .external_coefficient_read_data(
                    coefficient_rom_data[lane][63:0]));
        end
    endgenerate

    always_comb begin
        for (control_bank = 0; control_bank < 16;
                control_bank = control_bank + 1) begin
            luma_input_read_data[control_bank * 16 +: 16] =
                bank_input_read_data[control_bank];
            luma_intermediate_read_data[control_bank * 16 +: 16] =
                bank_intermediate_read_data[control_bank];
            if (active_pair8) begin
                bank_input_read_enable[control_bank] =
                    lane_input_read_enable[control_bank / 8];
                bank_input_read_address[control_bank] =
                    {1'b0, lane_input_read_address[control_bank / 8]};
                bank_input_write_enable[control_bank] =
                    lane_input_write_enable[control_bank / 8][control_bank % 8];
                bank_input_write_address[control_bank] =
                    {1'b0, lane_input_write_address[control_bank / 8][(control_bank % 8) * 3 +: 3]};
                bank_input_write_data[control_bank] =
                    lane_input_write_data[control_bank / 8][(control_bank % 8) * 16 +: 16];
                bank_intermediate_read_enable[control_bank] =
                    lane_intermediate_read_enable[control_bank / 8];
                bank_intermediate_read_address[control_bank] =
                    {1'b0, lane_intermediate_read_address[control_bank / 8]};
                bank_intermediate_write_enable[control_bank] =
                    lane_intermediate_write_enable[control_bank / 8][control_bank % 8];
                bank_intermediate_write_address[control_bank] =
                    {1'b0, lane_intermediate_write_address[control_bank / 8][(control_bank % 8) * 3 +: 3]};
                bank_intermediate_write_data[control_bank] =
                    lane_intermediate_write_data[control_bank / 8][(control_bank % 8) * 16 +: 16];
            end else begin
                bank_input_read_enable[control_bank] = luma_input_read_enable;
                bank_input_read_address[control_bank] = luma_input_read_address;
                bank_input_write_enable[control_bank] =
                    luma_input_write_enable[control_bank];
                bank_input_write_address[control_bank] =
                    luma_input_write_address[control_bank * 4 +: 4];
                bank_input_write_data[control_bank] =
                    luma_input_write_data[control_bank * 16 +: 16];
                bank_intermediate_read_enable[control_bank] =
                    luma_intermediate_read_enable;
                bank_intermediate_read_address[control_bank] =
                    luma_intermediate_read_address;
                bank_intermediate_write_enable[control_bank] =
                    luma_intermediate_write_enable[control_bank];
                bank_intermediate_write_address[control_bank] =
                    luma_intermediate_write_address[control_bank * 4 +: 4];
                bank_intermediate_write_data[control_bank] =
                    luma_intermediate_write_data[control_bank * 16 +: 16];
            end
        end
        for (control_bank = 0; control_bank < 8;
                control_bank = control_bank + 1) begin
            lane_input_read_data[0][control_bank * 16 +: 16] =
                bank_input_read_data[control_bank];
            lane_input_read_data[1][control_bank * 16 +: 16] =
                bank_input_read_data[control_bank + 8];
            lane_intermediate_read_data[0][control_bank * 16 +: 16] =
                bank_intermediate_read_data[control_bank];
            lane_intermediate_read_data[1][control_bank * 16 +: 16] =
                bank_intermediate_read_data[control_bank + 8];
        end
    end

    genvar bank;
    generate
        for (bank = 0; bank < 16; bank = bank + 1) begin : shared_banks
            hevc_transform_bank16 input_bank (
                .clk, .write_enable(bank_input_write_enable[bank]),
                .write_address(bank_input_write_address[bank]),
                .write_data(bank_input_write_data[bank]),
                .read_enable(bank_input_read_enable[bank]),
                .read_address(bank_input_read_address[bank]),
                .read_data(bank_input_read_data[bank]));
            hevc_transform_bank16 intermediate_bank (
                .clk, .write_enable(bank_intermediate_write_enable[bank]),
                .write_address(bank_intermediate_write_address[bank]),
                .write_data(bank_intermediate_write_data[bank]),
                .read_enable(bank_intermediate_read_enable[bank]),
                .read_address(bank_intermediate_read_address[bank]),
                .read_data(bank_intermediate_read_data[bank]));
        end
    endgenerate

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            active_pair8 <= 1'b0;
            input_plane <= 1'b0;
            output_plane <= 1'b0;
            input_count <= '0;
            done <= 1'b0;
        end else begin
            done <= 1'b0;
            if (command_fire) begin
                active_pair8 <= command_pair8;
                input_plane <= 1'b0;
                output_plane <= 1'b0;
                input_count <= '0;
            end
            if (active_pair8 && input_fire) begin
                if (input_count == 63) begin
                    input_count <= '0;
                    if (!input_plane) input_plane <= 1'b1;
                end else input_count <= input_count + 1'b1;
            end
            if (active_pair8 && output_fire && m_block_last && !output_plane)
                output_plane <= 1'b1;
            if ((!active_pair8 && luma_done) ||
                    (active_pair8 && output_fire && m_pair_last))
                done <= 1'b1;
        end
    end

    logic unused;
    assign unused = luma_protocol_error ^ lane_done[0] ^ lane_done[1];
endmodule
