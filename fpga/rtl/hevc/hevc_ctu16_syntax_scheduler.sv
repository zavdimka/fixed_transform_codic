module hevc_ctu16_syntax_scheduler (
    input  logic       clk,
    input  logic       rst_n,

    input  logic       ctu_start_valid,
    output logic       ctu_start_ready,
    input  logic       ctu_last_in_slice,

    input  logic       cu_valid,
    output logic       cu_ready,
    input  logic       cu_luma_mode_dc,
    input  logic       cu_luma_cbf,

    input  logic       coefficient_valid,
    output logic       coefficient_ready,
    input  logic [1:0] coefficient_kind,
    input  logic       coefficient_bin,
    input  logic [7:0] coefficient_context_address,
    input  logic       coefficient_block_done,

    output logic       m_valid,
    input  logic       m_ready,
    output logic [1:0] m_kind,
    output logic       m_bin,
    output logic [7:0] m_context_address,
    output logic       m_last,

    output logic       ctu_done,
    output logic       slice_termination,
    output logic       protocol_error,
    output logic       busy
);
    localparam logic [1:0] CABAC_TERMINATE = 2'd2;

    typedef enum logic [2:0] {
        IDLE,
        WAIT_CU,
        PREFIX,
        COEFFICIENT,
        TERMINATE
    } state_t;

    state_t state;
    logic ctu_last_register;
    logic cu_luma_cbf_register;

    logic prefix_start_valid;
    logic prefix_start_ready;
    logic prefix_m_valid;
    logic prefix_m_ready;
    logic [1:0] prefix_m_kind;
    logic prefix_m_bin;
    logic [7:0] prefix_m_context_address;
    logic unused_prefix_m_last;
    logic prefix_done;
    logic unused_prefix_busy;

    wire ctu_start_fire = ctu_start_valid && ctu_start_ready;
    wire cu_fire = cu_valid && cu_ready;
    wire output_fire = m_valid && m_ready;
    wire coefficient_kind_valid = (coefficient_kind == 2'd0) ||
        (coefficient_kind == 2'd1);

    assign ctu_start_ready = (state == IDLE);
    assign prefix_start_valid = (state == WAIT_CU) && cu_valid;
    assign cu_ready = (state == WAIT_CU) && prefix_start_ready;
    assign prefix_m_ready = (state == PREFIX) && m_ready;
    assign coefficient_ready = (state == COEFFICIENT) &&
        (!coefficient_valid || !coefficient_kind_valid || m_ready);
    assign busy = (state != IDLE);

    always_comb begin
        m_valid = 1'b0;
        m_kind = 2'd0;
        m_bin = 1'b0;
        m_context_address = 8'd0;
        m_last = 1'b0;

        case (state)
            PREFIX: begin
                m_valid = prefix_m_valid;
                m_kind = prefix_m_kind;
                m_bin = prefix_m_bin;
                m_context_address = prefix_m_context_address;
            end
            COEFFICIENT: begin
                m_valid = coefficient_valid && coefficient_kind_valid;
                m_kind = coefficient_kind;
                m_bin = coefficient_bin;
                m_context_address = coefficient_context_address;
            end
            TERMINATE: begin
                m_valid = 1'b1;
                m_kind = CABAC_TERMINATE;
                m_bin = ctu_last_register;
                m_last = 1'b1;
            end
            default: begin
            end
        endcase
    end

    hevc_ctu16_intra_prefix prefix (
        .clk(clk),
        .rst_n(rst_n),
        .start_valid(prefix_start_valid),
        .start_ready(prefix_start_ready),
        .luma_mode_dc(cu_luma_mode_dc),
        .luma_cbf(cu_luma_cbf),
        .m_valid(prefix_m_valid),
        .m_ready(prefix_m_ready),
        .m_kind(prefix_m_kind),
        .m_bin(prefix_m_bin),
        .m_context_address(prefix_m_context_address),
        .m_last(unused_prefix_m_last),
        .done(prefix_done),
        .busy(unused_prefix_busy)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            ctu_last_register <= 1'b0;
            cu_luma_cbf_register <= 1'b0;
            ctu_done <= 1'b0;
            slice_termination <= 1'b0;
            protocol_error <= 1'b0;
        end else begin
            ctu_done <= 1'b0;
            slice_termination <= 1'b0;

            if (coefficient_block_done && (state != COEFFICIENT))
                protocol_error <= 1'b1;
            if (coefficient_valid && coefficient_ready &&
                !coefficient_kind_valid)
                protocol_error <= 1'b1;

            case (state)
                IDLE: begin
                    if (ctu_start_fire) begin
                        ctu_last_register <= ctu_last_in_slice;
                        protocol_error <= 1'b0;
                        state <= WAIT_CU;
                    end
                end
                WAIT_CU: begin
                    if (cu_fire) begin
                        cu_luma_cbf_register <= cu_luma_cbf;
                        state <= PREFIX;
                    end
                end
                PREFIX: begin
                    if (prefix_done)
                        state <= cu_luma_cbf_register ? COEFFICIENT : TERMINATE;
                end
                COEFFICIENT: begin
                    if (coefficient_block_done)
                        state <= TERMINATE;
                end
                TERMINATE: begin
                    if (output_fire) begin
                        ctu_done <= 1'b1;
                        slice_termination <= ctu_last_register;
                        state <= IDLE;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
