module hevc_idr_ctu64_nal #(
    parameter integer CTU_COLUMNS = 20,
    parameter integer CTU_ROWS = 12,
    parameter logic [5:0] NAL_UNIT_TYPE = 6'd20
) (
    input  logic               clk,
    input  logic               rst_n,

    input  logic               start_valid,
    output logic               start_ready,
    input  logic [5:0]         slice_row,
    input  logic [5:0]         qp,
    input  logic               no_output_of_prior_pics,

    input  logic               ctu_start_valid,
    output logic               ctu_start_ready,

    input  logic               cu_valid,
    output logic               cu_ready,
    input  logic               cu_luma_mode_dc,
    input  logic               cu_luma_cbf,

    input  logic               s_valid,
    output logic               s_ready,
    input  logic [7:0]         s_raster_address,
    input  logic signed [15:0] s_coefficient,
    input  logic               s_block_last,

    output logic               m_valid,
    input  logic               m_ready,
    output logic [7:0]         m_byte,
    output logic               m_last,

    output logic [5:0]         current_ctu_x,
    output logic               block_done,
    output logic               ctu_done,
    output logic               done,
    output logic               parameter_error,
    output logic               protocol_error,
    output logic               busy
);
    localparam logic [6:0] CTU_COLUMNS_VALUE = 7'(CTU_COLUMNS);
    localparam logic [6:0] CTU_ROWS_VALUE = 7'(CTU_ROWS);

    typedef enum logic [2:0] {
        IDLE,
        INIT_START,
        INIT_WAIT,
        START_COMPONENTS,
        ACTIVE
    } state_t;

    state_t state;
    logic [5:0] slice_row_register;
    logic [5:0] qp_register;
    logic no_output_register;
    logic [5:0] ctu_x_register;
    logic wrapper_parameter_error;
    logic wrapper_protocol_error;
    logic cabac_slice_done_seen;

    logic unused_cfg_ready;
    logic context_init_valid;
    logic context_init_ready;
    logic context_init_done;
    logic context_init_error;
    logic cabac_slice_start_valid;
    logic cabac_slice_start_ready;
    logic cabac_ctu_start_ready;
    logic cabac_cu_ready;
    logic cabac_s_ready;
    logic cabac_m_valid;
    logic cabac_m_ready;
    logic [7:0] cabac_m_byte;
    logic cabac_m_last;
    logic cabac_block_done;
    logic cabac_ctu_done;
    logic cabac_slice_done;
    logic cabac_protocol_error;
    logic cabac_busy;

    logic nal_start_valid;
    logic nal_start_ready;
    logic nal_s_ready;
    logic nal_done;
    logic nal_busy;
    logic nal_parameter_error;

    wire parameters_valid = ({1'b0, slice_row} < CTU_ROWS_VALUE) && (qp <= 51) &&
        (CTU_COLUMNS > 0) && (CTU_COLUMNS <= 64) &&
        (CTU_ROWS > 0) && (CTU_ROWS <= 64);
    wire start_fire = start_valid && start_ready;
    wire context_init_fire = context_init_valid && context_init_ready;
    wire components_start_fire = cabac_slice_start_valid &&
        cabac_slice_start_ready && nal_start_valid && nal_start_ready;
    wire ctu_start_fire = ctu_start_valid && ctu_start_ready;

    assign start_ready = (state == IDLE);
    assign context_init_valid = (state == INIT_START);

    assign cabac_slice_start_valid = (state == START_COMPONENTS) &&
        nal_start_ready;
    assign nal_start_valid = (state == START_COMPONENTS) &&
        cabac_slice_start_ready;

    assign ctu_start_ready = (state == ACTIVE) && cabac_ctu_start_ready &&
        !cabac_ctu_done;
    assign cu_ready = (state == ACTIVE) && cabac_cu_ready;
    assign s_ready = (state == ACTIVE) && cabac_s_ready;
    assign cabac_m_ready = nal_s_ready;

    assign current_ctu_x = ctu_x_register;
    assign block_done = cabac_block_done;
    assign ctu_done = cabac_ctu_done;
    assign parameter_error = wrapper_parameter_error ||
        context_init_error || nal_parameter_error;
    assign protocol_error = wrapper_protocol_error || cabac_protocol_error;
    assign busy = (state != IDLE) || cabac_busy || nal_busy;

    hevc_ctu64_cabac cabac_path (
        .clk(clk),
        .rst_n(rst_n),
        .cfg_valid(1'b0),
        .cfg_ready(unused_cfg_ready),
        .cfg_context_address(8'd0),
        .cfg_state_index(6'd0),
        .cfg_mps(1'b0),
        .context_init_valid(context_init_valid),
        .context_init_ready(context_init_ready),
        .context_init_slice_type(2'd2),
        .context_init_qp(qp_register),
        .context_init_done(context_init_done),
        .context_init_error(context_init_error),
        .slice_start_valid(cabac_slice_start_valid),
        .slice_start_ready(cabac_slice_start_ready),
        .ctu_start_valid(ctu_start_valid && (state == ACTIVE) &&
            !cabac_ctu_done),
        .ctu_start_ready(cabac_ctu_start_ready),
        .ctu_x(ctu_x_register),
        .ctu_last_in_slice({1'b0, ctu_x_register} == CTU_COLUMNS_VALUE - 1'b1),
        .cu_valid(cu_valid && (state == ACTIVE)),
        .cu_ready(cabac_cu_ready),
        .cu_luma_mode_dc(cu_luma_mode_dc),
        .cu_luma_cbf(cu_luma_cbf),
        .s_valid(s_valid && (state == ACTIVE)),
        .s_ready(cabac_s_ready),
        .s_raster_address(s_raster_address),
        .s_coefficient(s_coefficient),
        .s_block_last(s_block_last),
        .m_valid(cabac_m_valid),
        .m_ready(cabac_m_ready),
        .m_byte(cabac_m_byte),
        .m_last(cabac_m_last),
        .block_done(cabac_block_done),
        .ctu_done(cabac_ctu_done),
        .slice_done(cabac_slice_done),
        .protocol_error(cabac_protocol_error),
        .busy(cabac_busy)
    );

    hevc_idr_slice_nal #(
        .CTU_COLUMNS(CTU_COLUMNS),
        .CTU_ROWS(CTU_ROWS),
        .NAL_UNIT_TYPE(NAL_UNIT_TYPE)
    ) nal_path (
        .clk(clk),
        .rst_n(rst_n),
        .start_valid(nal_start_valid),
        .start_ready(nal_start_ready),
        .slice_row(slice_row_register),
        .qp(qp_register),
        .no_output_of_prior_pics(no_output_register),
        .s_valid(cabac_m_valid),
        .s_ready(nal_s_ready),
        .s_byte(cabac_m_byte),
        .s_last(cabac_m_last),
        .m_valid(m_valid),
        .m_ready(m_ready),
        .m_byte(m_byte),
        .m_last(m_last),
        .done(nal_done),
        .busy(nal_busy),
        .parameter_error(nal_parameter_error)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            slice_row_register <= 6'd0;
            qp_register <= 6'd0;
            no_output_register <= 1'b0;
            ctu_x_register <= 6'd0;
            wrapper_parameter_error <= 1'b0;
            wrapper_protocol_error <= 1'b0;
            cabac_slice_done_seen <= 1'b0;
            done <= 1'b0;
        end else begin
            wrapper_parameter_error <= 1'b0;
            done <= 1'b0;

            if (cabac_slice_done)
                cabac_slice_done_seen <= 1'b1;

            case (state)
                IDLE: begin
                    if (start_fire) begin
                        if (parameters_valid) begin
                            slice_row_register <= slice_row;
                            qp_register <= qp;
                            no_output_register <= no_output_of_prior_pics;
                            ctu_x_register <= 6'd0;
                            wrapper_protocol_error <= 1'b0;
                            cabac_slice_done_seen <= 1'b0;
                            state <= INIT_START;
                        end else begin
                            wrapper_parameter_error <= 1'b1;
                        end
                    end
                end
                INIT_START: begin
                    if (context_init_fire)
                        state <= INIT_WAIT;
                end
                INIT_WAIT: begin
                    if (context_init_done)
                        state <= START_COMPONENTS;
                end
                START_COMPONENTS: begin
                    if (components_start_fire)
                        state <= ACTIVE;
                end
                ACTIVE: begin
                    if (ctu_start_fire &&
                        ({1'b0, ctu_x_register} >= CTU_COLUMNS_VALUE)) begin
                        wrapper_protocol_error <= 1'b1;
                    end
                    if (cabac_ctu_done &&
                        ({1'b0, ctu_x_register} < CTU_COLUMNS_VALUE - 1'b1)) begin
                        ctu_x_register <= ctu_x_register + 1'b1;
                    end
                    if (nal_done) begin
                        done <= 1'b1;
                        if (!cabac_slice_done_seen && !cabac_slice_done)
                            wrapper_protocol_error <= 1'b1;
                        state <= IDLE;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
