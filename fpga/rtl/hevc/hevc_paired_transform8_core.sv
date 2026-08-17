module hevc_paired_transform8_core (
    input logic clk, input logic rst_n,
    input logic command_valid, output logic command_ready,
    input logic command_inverse,
    input logic s_valid, output logic s_ready,
    input logic signed [15:0] s_data,
    output logic m_valid, input logic m_ready,
    output logic signed [15:0] m_data,
    output logic m_plane, output logic [2:0] m_x, output logic [2:0] m_y,
    output logic m_block_last, output logic m_pair_last,
    output logic done, output logic busy
);
    logic input_plane, output_plane;
    logic [5:0] input_count;
    logic lane0_command_ready, lane1_command_ready;
    logic lane0_s_ready, lane1_s_ready;
    logic lane0_m_valid, lane1_m_valid, lane0_m_ready, lane1_m_ready;
    logic signed [15:0] lane0_m_data, lane1_m_data;
    logic [2:0] lane0_m_x, lane0_m_y, lane1_m_x, lane1_m_y;
    logic lane0_m_last, lane1_m_last, lane0_done, lane1_done;
    logic lane0_busy, lane1_busy;
    logic signed [127:0] samples0, samples1;
    logic signed [63:0] coefficients0, coefficients1;
    logic signed [31:0] sum0, sum1;

    wire command_fire = command_valid && command_ready;
    wire input_fire = s_valid && s_ready;
    wire output_fire = m_valid && m_ready;

    assign command_ready = lane0_command_ready && lane1_command_ready;
    assign s_ready = input_plane ? lane1_s_ready : lane0_s_ready;
    assign lane0_m_ready = !output_plane && m_ready;
    assign lane1_m_ready = output_plane && m_ready;
    assign m_valid = output_plane ? lane1_m_valid : lane0_m_valid;
    assign m_data = output_plane ? lane1_m_data : lane0_m_data;
    assign m_plane = output_plane;
    assign m_x = output_plane ? lane1_m_x : lane0_m_x;
    assign m_y = output_plane ? lane1_m_y : lane0_m_y;
    assign m_block_last = output_plane ? lane1_m_last : lane0_m_last;
    assign m_pair_last = output_plane && lane1_m_last;
    assign busy = lane0_busy || lane1_busy;

    hevc_transform_mac8x2 mac (
        .samples_a(samples0), .coefficients_a(coefficients0), .sum_a(sum0),
        .samples_b(samples1), .coefficients_b(coefficients1), .sum_b(sum1));

    /* verilator lint_off PINMISSING */
    hevc_stream_transform_lane8 lane0 (
        .clk, .rst_n, .command_valid(command_valid && lane1_command_ready),
        .command_ready(lane0_command_ready), .command_inverse,
        .s_valid(s_valid && !input_plane), .s_ready(lane0_s_ready), .s_data,
        .m_valid(lane0_m_valid), .m_ready(lane0_m_ready),
        .m_data(lane0_m_data), .m_x(lane0_m_x), .m_y(lane0_m_y),
        .m_block_last(lane0_m_last), .done(lane0_done), .busy(lane0_busy),
        .mac_samples(samples0), .mac_coefficients(coefficients0), .mac_sum(sum0),
        .external_coefficient_read_data('0));
    hevc_stream_transform_lane8 lane1 (
        .clk, .rst_n, .command_valid(command_valid && lane0_command_ready),
        .command_ready(lane1_command_ready), .command_inverse,
        .s_valid(s_valid && input_plane), .s_ready(lane1_s_ready), .s_data,
        .m_valid(lane1_m_valid), .m_ready(lane1_m_ready),
        .m_data(lane1_m_data), .m_x(lane1_m_x), .m_y(lane1_m_y),
        .m_block_last(lane1_m_last), .done(lane1_done), .busy(lane1_busy),
        .mac_samples(samples1), .mac_coefficients(coefficients1), .mac_sum(sum1),
        .external_coefficient_read_data('0));
    /* verilator lint_on PINMISSING */

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            input_plane <= 1'b0;
            output_plane <= 1'b0;
            input_count <= '0;
            done <= 1'b0;
        end else begin
            done <= 1'b0;
            if (command_fire) begin
                input_plane <= 1'b0;
                output_plane <= 1'b0;
                input_count <= '0;
            end
            if (input_fire) begin
                if (input_count == 63) begin
                    input_count <= '0;
                    if (!input_plane) input_plane <= 1'b1;
                end else input_count <= input_count + 1'b1;
            end
            if (output_fire && m_block_last && !output_plane)
                output_plane <= 1'b1;
            if (output_fire && m_pair_last) begin
                output_plane <= 1'b0;
                done <= 1'b1;
            end
        end
    end

    logic unused_done;
    assign unused_done = lane0_done ^ lane1_done;
endmodule
