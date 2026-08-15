module hevc_forward_transform8 (
    input logic clk, input logic rst_n,
    input logic s_valid, output logic s_ready, input logic signed [8:0] s_residual,
    output logic m_valid, input logic m_ready, output logic signed [15:0] m_coefficient,
    output logic [2:0] m_x, output logic [2:0] m_y, output logic m_block_last
);
    hevc_transform8_core #(.INVERSE(1'b0)) core (
        .clk, .rst_n, .s_valid, .s_ready,
        .s_data({{7{s_residual[8]}}, s_residual}),
        .m_valid, .m_ready, .m_data(m_coefficient), .m_x, .m_y, .m_block_last
    );
endmodule
