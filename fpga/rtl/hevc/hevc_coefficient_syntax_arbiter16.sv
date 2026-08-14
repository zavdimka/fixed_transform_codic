module hevc_coefficient_syntax_arbiter16 (
    input  logic       clk,
    input  logic       rst_n,

    input  logic       s_start_valid,
    output logic       s_start_ready,

    input  logic       s_last_valid,
    output logic       s_last_ready,
    input  logic       s_last_bin,
    input  logic       s_last_bypass,
    input  logic       s_last_axis_y,
    input  logic [3:0] s_last_context_index,
    input  logic       s_last_syntax_last,

    input  logic       s_significance_valid,
    output logic       s_significance_ready,
    input  logic       s_significance_bin,
    input  logic       s_significance_coded_sub_block,
    input  logic [4:0] s_significance_context_index,
    input  logic [7:0] s_significance_scan_position,
    input  logic       s_significance_done,

    input  logic       s_level_valid,
    output logic       s_level_ready,
    input  logic       s_level_bin,
    input  logic       s_level_bypass,
    input  logic [1:0] s_level_kind,
    input  logic [4:0] s_level_context_index,
    input  logic [3:0] s_level_group_scan_position,
    input  logic [3:0] s_level_coefficient_index,
    input  logic       s_level_done,

    output logic       m_valid,
    input  logic       m_ready,
    output logic       m_bin,
    output logic       m_bypass,
    output logic [1:0] m_source,
    output logic [1:0] m_level_kind,
    output logic [4:0] m_context_index,
    output logic       m_last_axis_y,
    output logic       m_significance_coded_sub_block,
    output logic [7:0] m_scan_position,
    output logic [3:0] m_group_scan_position,
    output logic [3:0] m_coefficient_index,
    output logic       block_done,
    output logic       busy
);
    localparam logic [1:0] SOURCE_LAST = 2'd0;
    localparam logic [1:0] SOURCE_SIGNIFICANCE = 2'd1;
    localparam logic [1:0] SOURCE_LEVEL = 2'd2;

    typedef enum logic [1:0] {
        IDLE, LAST, SIGNIFICANCE, LEVEL
    } state_t;
    state_t state;

    always_comb begin
        s_start_ready = (state == IDLE);
        s_last_ready = 1'b0;
        s_significance_ready = 1'b0;
        s_level_ready = 1'b0;

        m_valid = 1'b0;
        m_bin = 1'b0;
        m_bypass = 1'b0;
        m_source = SOURCE_LAST;
        m_level_kind = 2'd0;
        m_context_index = 5'd0;
        m_last_axis_y = 1'b0;
        m_significance_coded_sub_block = 1'b0;
        m_scan_position = 8'd0;
        m_group_scan_position = 4'd0;
        m_coefficient_index = 4'd0;
        busy = (state != IDLE);

        case (state)
            LAST: begin
                m_valid = s_last_valid;
                s_last_ready = m_ready;
                m_bin = s_last_bin;
                m_bypass = s_last_bypass;
                m_source = SOURCE_LAST;
                m_context_index = {1'b0, s_last_context_index};
                m_last_axis_y = s_last_axis_y;
            end
            SIGNIFICANCE: begin
                m_valid = s_significance_valid;
                s_significance_ready = m_ready;
                m_bin = s_significance_bin;
                m_source = SOURCE_SIGNIFICANCE;
                m_context_index = s_significance_context_index;
                m_significance_coded_sub_block =
                    s_significance_coded_sub_block;
                m_scan_position = s_significance_scan_position;
            end
            LEVEL: begin
                m_valid = s_level_valid;
                s_level_ready = m_ready;
                m_bin = s_level_bin;
                m_bypass = s_level_bypass;
                m_source = SOURCE_LEVEL;
                m_level_kind = s_level_kind;
                m_context_index = s_level_context_index;
                m_group_scan_position = s_level_group_scan_position;
                m_coefficient_index = s_level_coefficient_index;
            end
            default: begin
            end
        endcase
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            block_done <= 1'b0;
        end else begin
            block_done <= 1'b0;
            case (state)
                IDLE: begin
                    if (s_start_valid) begin
                        state <= LAST;
                    end
                end
                LAST: begin
                    if (s_last_valid && s_last_ready &&
                            s_last_syntax_last) begin
                        state <= SIGNIFICANCE;
                    end
                end
                SIGNIFICANCE: begin
                    if (s_significance_done) begin
                        state <= LEVEL;
                    end
                end
                default: begin
                    if (s_level_done) begin
                        state <= IDLE;
                        block_done <= 1'b1;
                    end
                end
            endcase
        end
    end
endmodule
