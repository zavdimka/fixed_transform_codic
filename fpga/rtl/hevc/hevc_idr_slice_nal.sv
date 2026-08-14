module hevc_idr_slice_nal #(
    parameter integer CTU_COLUMNS = 20,
    parameter integer CTU_ROWS = 12,
    parameter logic [5:0] NAL_UNIT_TYPE = 6'd20
) (
    input  logic       clk,
    input  logic       rst_n,

    input  logic       start_valid,
    output logic       start_ready,
    input  logic [5:0] slice_row,
    input  logic [5:0] qp,
    input  logic       no_output_of_prior_pics,

    input  logic       s_valid,
    output logic       s_ready,
    input  logic [7:0] s_byte,
    input  logic       s_last,

    output logic       m_valid,
    input  logic       m_ready,
    output logic [7:0] m_byte,
    output logic       m_last,

    output logic       done,
    output logic       busy,
    output logic       parameter_error
);
    typedef enum logic [1:0] {
        IDLE,
        HEADER,
        CABAC
    } state_t;

    localparam logic [5:0] CTU_ROWS_VALUE = 6'(CTU_ROWS);

    state_t state;
    logic wrapper_parameter_error;

    logic header_start_valid;
    logic header_start_ready;
    logic header_valid;
    logic header_ready;
    logic [7:0] header_data;
    logic header_last;
    logic header_busy;
    logic header_done;
    logic unused_header_done;
    logic header_parameter_error;

    logic nal_start_valid;
    logic nal_start_ready;
    logic nal_s_valid;
    logic nal_s_ready;
    logic [7:0] nal_s_data;
    logic nal_s_last;
    logic nal_busy;
    logic nal_parameter_error;

    wire parameters_valid = (slice_row < CTU_ROWS_VALUE) && (qp <= 51);
    wire start_fire = start_valid && start_ready;
    wire header_fire = header_valid && header_ready;
    wire cabac_fire = s_valid && s_ready;
    wire output_last_fire = m_valid && m_ready && m_last;

    assign start_ready = (state == IDLE) &&
        header_start_ready && nal_start_ready;
    assign header_start_valid = start_valid && (state == IDLE) &&
        nal_start_ready && parameters_valid;
    assign nal_start_valid = start_valid && (state == IDLE) &&
        header_start_ready && parameters_valid;

    assign header_ready = (state == HEADER) && nal_s_ready;
    assign s_ready = (state == CABAC) && nal_s_ready;

    always_comb begin
        nal_s_valid = 1'b0;
        nal_s_data = 8'h00;
        nal_s_last = 1'b0;

        case (state)
            HEADER: begin
                nal_s_valid = header_valid;
                nal_s_data = header_data;
            end
            CABAC: begin
                nal_s_valid = s_valid;
                nal_s_data = s_byte;
                nal_s_last = s_last;
            end
            default: begin
            end
        endcase
    end

    assign busy = (state != IDLE) || header_busy || nal_busy;
    assign parameter_error = wrapper_parameter_error ||
        header_parameter_error || nal_parameter_error;

    hevc_idr_slice_header #(
        .CTU_COLUMNS(CTU_COLUMNS),
        .CTU_ROWS(CTU_ROWS)
    ) slice_header (
        .clk(clk),
        .rst_n(rst_n),
        .start_valid(header_start_valid),
        .start_ready(header_start_ready),
        .slice_row(slice_row),
        .qp(qp),
        .no_output_of_prior_pics(no_output_of_prior_pics),
        .m_valid(header_valid),
        .m_ready(header_ready),
        .m_data(header_data),
        .m_last(header_last),
        .busy(header_busy),
        .done(header_done),
        .parameter_error(header_parameter_error)
    );

    hevc_nal_writer nal_writer (
        .clk(clk),
        .rst_n(rst_n),
        .start_valid(nal_start_valid),
        .start_ready(nal_start_ready),
        .nal_unit_type(NAL_UNIT_TYPE),
        .temporal_id_plus1(3'd1),
        .s_valid(nal_s_valid),
        .s_ready(nal_s_ready),
        .s_data(nal_s_data),
        .s_last(nal_s_last),
        .m_valid(m_valid),
        .m_ready(m_ready),
        .m_data(m_byte),
        .m_last(m_last),
        .busy(nal_busy),
        .parameter_error(nal_parameter_error)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            done <= 1'b0;
            wrapper_parameter_error <= 1'b0;
        end else begin
            done <= 1'b0;
            wrapper_parameter_error <= 1'b0;

            case (state)
                IDLE: begin
                    if (start_fire) begin
                        if (parameters_valid) begin
                            state <= HEADER;
                        end else begin
                            wrapper_parameter_error <= 1'b1;
                        end
                    end
                end
                HEADER: begin
                    if (header_fire && header_last)
                        state <= CABAC;
                end
                CABAC: begin
                    if (cabac_fire && s_last)
                        state <= IDLE;
                end
                default: state <= IDLE;
            endcase

            if (output_last_fire)
                done <= 1'b1;
        end
    end

    assign unused_header_done = header_done;
endmodule
