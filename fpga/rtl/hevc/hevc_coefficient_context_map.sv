module hevc_coefficient_context_map (
    input  logic       s_bypass,
    input  logic [1:0] s_source,
    input  logic [1:0] s_level_kind,
    input  logic [4:0] s_context_index,
    input  logic       s_last_axis_y,
    input  logic       s_significance_coded_sub_block,

    output logic [1:0] m_cabac_kind,
    output logic [7:0] m_context_address,
    output logic       m_context_valid
);
    localparam logic [1:0] SOURCE_LAST = 2'd0;
    localparam logic [1:0] SOURCE_SIGNIFICANCE = 2'd1;
    localparam logic [1:0] SOURCE_LEVEL = 2'd2;

    localparam logic [1:0] LEVEL_GREATER1 = 2'd0;
    localparam logic [1:0] LEVEL_GREATER2 = 2'd1;
    localparam logic [1:0] LEVEL_SIGN = 2'd2;
    localparam logic [1:0] LEVEL_REMAINING = 2'd3;

    localparam logic [1:0] CABAC_REGULAR = 2'd0;
    localparam logic [1:0] CABAC_BYPASS = 2'd1;

    localparam logic [7:0] CONTEXT_LAST_X = 8'd0;
    localparam logic [7:0] CONTEXT_LAST_Y = 8'd16;
    localparam logic [7:0] CONTEXT_CODED_SUB_BLOCK = 8'd32;
    localparam logic [7:0] CONTEXT_SIGNIFICANT = 8'd64;
    localparam logic [7:0] CONTEXT_GREATER1 = 8'd96;
    localparam logic [7:0] CONTEXT_GREATER2 = 8'd112;

    always_comb begin
        m_cabac_kind = s_bypass ? CABAC_BYPASS : CABAC_REGULAR;
        m_context_address = 8'd0;
        m_context_valid = 1'b1;

        if (s_bypass) begin
            case (s_source)
                SOURCE_LAST: begin
                    m_context_valid = 1'b1;
                end
                SOURCE_LEVEL: begin
                    m_context_valid =
                        (s_level_kind == LEVEL_SIGN) ||
                        (s_level_kind == LEVEL_REMAINING);
                end
                default: m_context_valid = 1'b0;
            endcase
        end else begin
            case (s_source)
                SOURCE_LAST: begin
                    m_context_valid = (s_context_index < 5'd15);
                    m_context_address =
                        (s_last_axis_y ? CONTEXT_LAST_Y : CONTEXT_LAST_X) +
                        {3'd0, s_context_index};
                end
                SOURCE_SIGNIFICANCE: begin
                    if (s_significance_coded_sub_block) begin
                        m_context_valid = (s_context_index < 5'd2);
                        m_context_address = CONTEXT_CODED_SUB_BLOCK +
                            {3'd0, s_context_index};
                    end else begin
                        m_context_valid = (s_context_index < 5'd28);
                        m_context_address = CONTEXT_SIGNIFICANT +
                            {3'd0, s_context_index};
                    end
                end
                SOURCE_LEVEL: begin
                    case (s_level_kind)
                        LEVEL_GREATER1: begin
                            m_context_valid = (s_context_index < 5'd16);
                            m_context_address = CONTEXT_GREATER1 +
                                {3'd0, s_context_index};
                        end
                        LEVEL_GREATER2: begin
                            m_context_valid = (s_context_index < 5'd4);
                            m_context_address = CONTEXT_GREATER2 +
                                {3'd0, s_context_index};
                        end
                        default: m_context_valid = 1'b0;
                    endcase
                end
                default: m_context_valid = 1'b0;
            endcase
        end
    end
endmodule
