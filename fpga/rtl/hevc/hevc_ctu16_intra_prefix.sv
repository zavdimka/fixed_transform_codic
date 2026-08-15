module hevc_ctu16_intra_prefix (
    input  logic       clk,
    input  logic       rst_n,

    input  logic       start_valid,
    output logic       start_ready,
    input  logic       luma_mode_dc,
    input  logic       luma_cbf,

    output logic       m_valid,
    input  logic       m_ready,
    output logic [1:0] m_kind,
    output logic       m_bin,
    output logic [7:0] m_context_address,
    output logic       m_last,

    output logic       done,
    output logic       busy
);
    localparam logic [1:0] CABAC_REGULAR = 2'd0;
    localparam logic [1:0] CABAC_BYPASS = 2'd1;

    localparam logic [7:0] CONTEXT_PART_SIZE = 8'd132;
    localparam logic [7:0] CONTEXT_INTRA_PRED_MODE = 8'd136;
    localparam logic [7:0] CONTEXT_CHROMA_PRED_MODE = 8'd137;
    localparam logic [7:0] CONTEXT_QT_CBF_LUMA = 8'd144;
    localparam logic [7:0] CONTEXT_QT_CBF_CHROMA = 8'd152;

    typedef enum logic [3:0] {
        IDLE,
        PART_MODE,
        MPM_FLAG,
        MPM_FIRST,
        MPM_SECOND,
        CHROMA_MODE,
        CBF_CB,
        CBF_CR,
        CBF_Y
    } state_t;

    state_t state;
    logic luma_mode_dc_register;
    logic luma_cbf_register;

    wire output_fire = m_valid && m_ready;

    assign start_ready = (state == IDLE);
    assign busy = (state != IDLE);

    always_comb begin
        m_valid = (state != IDLE);
        m_kind = CABAC_REGULAR;
        m_bin = 1'b0;
        m_context_address = 8'd0;
        m_last = 1'b0;

        case (state)
            PART_MODE: begin
                m_bin = 1'b1;
                m_context_address = CONTEXT_PART_SIZE;
            end
            MPM_FLAG: begin
                m_bin = 1'b1;
                m_context_address = CONTEXT_INTRA_PRED_MODE;
            end
            MPM_FIRST: begin
                m_kind = CABAC_BYPASS;
                m_bin = luma_mode_dc_register;
            end
            MPM_SECOND: begin
                m_kind = CABAC_BYPASS;
                m_bin = 1'b0;
            end
            CHROMA_MODE: begin
                m_context_address = CONTEXT_CHROMA_PRED_MODE;
            end
            CBF_CB, CBF_CR: begin
                m_context_address = CONTEXT_QT_CBF_CHROMA;
            end
            CBF_Y: begin
                m_bin = luma_cbf_register;
                m_context_address = CONTEXT_QT_CBF_LUMA + 1'b1;
                m_last = 1'b1;
            end
            default: begin
                m_valid = 1'b0;
            end
        endcase
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            luma_mode_dc_register <= 1'b0;
            luma_cbf_register <= 1'b0;
            done <= 1'b0;
        end else begin
            done <= 1'b0;
            if (state == IDLE) begin
                if (start_valid) begin
                    luma_mode_dc_register <= luma_mode_dc;
                    luma_cbf_register <= luma_cbf;
                    state <= PART_MODE;
                end
            end else if (output_fire) begin
                case (state)
                    PART_MODE: state <= MPM_FLAG;
                    MPM_FLAG: state <= MPM_FIRST;
                    MPM_FIRST: state <= luma_mode_dc_register ?
                        MPM_SECOND : CHROMA_MODE;
                    MPM_SECOND: state <= CHROMA_MODE;
                    CHROMA_MODE: state <= CBF_CB;
                    CBF_CB: state <= CBF_CR;
                    CBF_CR: state <= CBF_Y;
                    CBF_Y: begin
                        state <= IDLE;
                        done <= 1'b1;
                    end
                    default: state <= IDLE;
                endcase
            end
        end
    end
endmodule
