module hevc_shared_transform_service (
    input  logic               clk,
    input  logic               rst_n,

    input  logic               y_request_valid,
    output logic               y_request_ready,
    input  logic               y_inverse,
    input  logic               y_s_valid,
    output logic               y_s_ready,
    input  logic signed [15:0] y_s_data,
    output logic               y_m_valid,
    input  logic               y_m_ready,
    output logic signed [15:0] y_m_data,
    output logic [3:0]         y_m_x,
    output logic [3:0]         y_m_y,
    output logic               y_m_block_last,

    input  logic               cb_request_valid,
    output logic               cb_request_ready,
    input  logic               cb_inverse,
    input  logic               cb_s_valid,
    output logic               cb_s_ready,
    input  logic signed [15:0] cb_s_data,
    output logic               cb_m_valid,
    input  logic               cb_m_ready,
    output logic signed [15:0] cb_m_data,
    output logic [2:0]         cb_m_x,
    output logic [2:0]         cb_m_y,
    output logic               cb_m_block_last,

    input  logic               cr_request_valid,
    output logic               cr_request_ready,
    input  logic               cr_inverse,
    input  logic               cr_s_valid,
    output logic               cr_s_ready,
    input  logic signed [15:0] cr_s_data,
    output logic               cr_m_valid,
    input  logic               cr_m_ready,
    output logic signed [15:0] cr_m_data,
    output logic [2:0]         cr_m_x,
    output logic [2:0]         cr_m_y,
    output logic               cr_m_block_last,

    output logic               block_done,
    output logic [1:0]         completed_plane,
    output logic               protocol_error,
    output logic               busy
);
    logic service_command_valid;
    logic service_command_ready;
    logic service_size8;
    logic service_inverse;
    logic [1:0] service_plane;
    logic service_s_valid;
    logic service_s_ready;
    logic signed [15:0] service_s_data;
    logic service_m_valid;
    logic service_m_ready;
    logic signed [15:0] service_m_data;
    logic [3:0] service_m_x;
    logic [3:0] service_m_y;
    logic service_m_block_last;
    logic scheduler_error;
    logic scheduler_busy;
    logic core_error;
    logic core_busy;
    logic core_done;

    hevc_shared_transform_scheduler scheduler (
        .clk, .rst_n,
        .y_request_valid, .y_request_ready, .y_inverse,
        .y_s_valid, .y_s_ready, .y_s_data,
        .y_m_valid, .y_m_ready, .y_m_data, .y_m_x, .y_m_y,
        .y_m_block_last,
        .cb_request_valid, .cb_request_ready, .cb_inverse,
        .cb_s_valid, .cb_s_ready, .cb_s_data,
        .cb_m_valid, .cb_m_ready, .cb_m_data, .cb_m_x, .cb_m_y,
        .cb_m_block_last,
        .cr_request_valid, .cr_request_ready, .cr_inverse,
        .cr_s_valid, .cr_s_ready, .cr_s_data,
        .cr_m_valid, .cr_m_ready, .cr_m_data, .cr_m_x, .cr_m_y,
        .cr_m_block_last,
        .service_command_valid, .service_command_ready,
        .service_size8, .service_inverse, .service_plane,
        .service_s_valid, .service_s_ready, .service_s_data,
        .service_m_valid, .service_m_ready, .service_m_data,
        .service_m_x, .service_m_y, .service_m_block_last,
        .block_done, .completed_plane,
        .protocol_error(scheduler_error), .busy(scheduler_busy)
    );

    hevc_shared_transform_core core (
        .clk, .rst_n,
        .command_valid(service_command_valid),
        .command_ready(service_command_ready),
        .command_size8(service_size8),
        .command_inverse(service_inverse),
        .s_valid(service_s_valid), .s_ready(service_s_ready),
        .s_data(service_s_data),
        .m_valid(service_m_valid), .m_ready(service_m_ready),
        .m_data(service_m_data), .m_x(service_m_x), .m_y(service_m_y),
        .m_block_last(service_m_block_last), .done(core_done),
        .protocol_error(core_error), .busy(core_busy)
    );

    assign protocol_error = scheduler_error | core_error;
    assign busy = scheduler_busy | core_busy;

    logic unused_service_metadata;
    assign unused_service_metadata = ^{service_plane, core_done};
endmodule
