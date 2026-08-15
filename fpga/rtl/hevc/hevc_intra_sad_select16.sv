module hevc_intra_sad_select16 (
    input  logic              clk,
    input  logic              rst_n,

    input  logic              s_valid,
    output logic              s_ready,
    input  logic signed [8:0] s_dc_residual,
    input  logic signed [8:0] s_planar_residual,
    input  logic              s_block_last,

    output logic              m_valid,
    input  logic              m_ready,
    output logic              m_planar_selected,
    output logic [16:0]       m_dc_sad,
    output logic [16:0]       m_planar_sad
);
    logic [16:0] dc_sad_accumulator;
    logic [16:0] planar_sad_accumulator;
    logic [8:0] dc_absolute;
    logic [8:0] planar_absolute;
    logic [16:0] dc_sad_next;
    logic [16:0] planar_sad_next;

    assign s_ready = !m_valid || m_ready;
    assign dc_absolute = s_dc_residual[8]
                       ? (~s_dc_residual + 1'b1) : s_dc_residual;
    assign planar_absolute = s_planar_residual[8]
                           ? (~s_planar_residual + 1'b1) : s_planar_residual;
    assign dc_sad_next = dc_sad_accumulator + {8'b0, dc_absolute};
    assign planar_sad_next = planar_sad_accumulator
                           + {8'b0, planar_absolute};

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            dc_sad_accumulator     <= '0;
            planar_sad_accumulator <= '0;
            m_valid                <= 1'b0;
            m_planar_selected      <= 1'b0;
            m_dc_sad               <= '0;
            m_planar_sad           <= '0;
        end else begin
            if (m_valid && m_ready) begin
                m_valid <= 1'b0;
            end

            if (s_valid && s_ready) begin
                if (s_block_last) begin
                    m_valid                <= 1'b1;
                    m_dc_sad               <= dc_sad_next;
                    m_planar_sad           <= planar_sad_next;
                    m_planar_selected      <= planar_sad_next < dc_sad_next;
                    dc_sad_accumulator     <= '0;
                    planar_sad_accumulator <= '0;
                end else begin
                    dc_sad_accumulator     <= dc_sad_next;
                    planar_sad_accumulator <= planar_sad_next;
                end
            end
        end
    end
endmodule
