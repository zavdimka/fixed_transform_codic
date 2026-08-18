module custom_pixel_ctu_entropy_writer36 (
    input  logic                       clk,
    input  logic                       rst_n,

    input  logic                       stripe_start_valid,
    output logic                       stripe_start_ready,
    input  logic                       stripe_finish_valid,
    output logic                       stripe_finish_ready,
    output logic                       stripe_finish_done,
    input  logic                       quality24,
    input  logic [16:0]                base_limit_bits,
    input  logic [16:0]                enhancement_limit_bits,
    input  logic [16:0]                base_reserved_bits,
    input  logic [16:0]                enhancement_reserved_bits,

    input  logic                       ctu_start_valid,
    output logic                       ctu_start_ready,
    input  logic                       ctu_has_left,
    input  logic [127:0]               ctu_left_y,
    input  logic [63:0]                ctu_left_cb,
    input  logic [63:0]                ctu_left_cr,
    input  logic                       s_valid,
    output logic                       s_ready,
    input  logic [127:0]               s_row,

    output logic                       m_valid,
    input  logic                       m_ready,
    output logic                       m_layer,
    output logic [7:0]                 m_byte,

    output logic                       frontend_done,
    output logic                       ctu_done,
    output logic                       busy,
    output logic                       fatal_error,
    output logic                       coefficient_saturated,
    output logic [31:0]                dc_satd,
    output logic [31:0]                horizontal_satd,
    output logic [16:0]                base_used_bits,
    output logic [16:0]                enhancement_used_bits,
    output logic [12:0]                base_byte_count,
    output logic [12:0]                enhancement_byte_count
);
    logic prefix_valid, prefix_ready;
    logic [1:0] prefix_mode;
    logic command_valid, command_ready;
    logic [1:0] command_pair;
    logic residual_valid, residual_ready, residual_last;
    logic signed [127:0] residual_row_a, residual_row_b;
    logic frontend_busy, frontend_error;
    logic entropy_busy, entropy_error;
    logic unused_transform_done, unused_block_done, unused_pair_done;
    logic unused_drop_pulse, unused_drop_layer;

    custom_intra_residual_frontend frontend (
        .clk(clk), .rst_n(rst_n),
        .start_valid(ctu_start_valid), .start_ready(ctu_start_ready),
        .has_left(ctu_has_left),
        .left_y(ctu_left_y), .left_cb(ctu_left_cb), .left_cr(ctu_left_cr),
        .s_valid(s_valid), .s_ready(s_ready), .s_row(s_row),
        .prefix_valid(prefix_valid), .prefix_ready(prefix_ready),
        .prefix_mode(prefix_mode),
        .command_valid(command_valid), .command_ready(command_ready),
        .command_pair(command_pair),
        .m_valid(residual_valid), .m_ready(residual_ready),
        .m_row_a(residual_row_a), .m_row_b(residual_row_b),
        .m_last(residual_last),
        .dc_satd(dc_satd), .horizontal_satd(horizontal_satd),
        .done(frontend_done), .busy(frontend_busy),
        .protocol_error(frontend_error)
    );

    custom_ctu_entropy_writer36 entropy (
        .clk(clk), .rst_n(rst_n),
        .start_valid(stripe_start_valid), .start_ready(stripe_start_ready),
        .finish_valid(stripe_finish_valid), .finish_ready(stripe_finish_ready),
        .finish_done(stripe_finish_done),
        .command_quality24(quality24),
        .base_limit_bits(base_limit_bits),
        .enhancement_limit_bits(enhancement_limit_bits),
        .base_reserved_bits(base_reserved_bits),
        .enhancement_reserved_bits(enhancement_reserved_bits),
        .prefix_valid(prefix_valid), .prefix_ready(prefix_ready),
        .prefix_mode(prefix_mode),
        .command_valid(command_valid), .command_ready(command_ready),
        .s_valid(residual_valid), .s_ready(residual_ready),
        .s_row_a(residual_row_a), .s_row_b(residual_row_b),
        .m_valid(m_valid), .m_ready(m_ready),
        .m_layer(m_layer), .m_byte(m_byte),
        .transform_done(unused_transform_done),
        .block_done(unused_block_done), .pair_done(unused_pair_done),
        .ctu_done(ctu_done), .drop_pulse(unused_drop_pulse),
        .drop_layer(unused_drop_layer),
        .busy(entropy_busy), .fatal_error(entropy_error),
        .coefficient_saturated(coefficient_saturated),
        .base_used_bits(base_used_bits),
        .enhancement_used_bits(enhancement_used_bits),
        .base_byte_count(base_byte_count),
        .enhancement_byte_count(enhancement_byte_count)
    );

    assign busy = frontend_busy || entropy_busy;
    assign fatal_error = frontend_error || entropy_error;

    logic unused_frontend_signals;
    assign unused_frontend_signals = residual_last ^ command_pair[0]
                                   ^ command_pair[1];
endmodule
