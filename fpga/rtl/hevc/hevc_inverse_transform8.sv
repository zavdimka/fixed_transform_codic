module hevc_inverse_transform8 (
    input logic clk, input logic rst_n,
    input logic s_valid, output logic s_ready, input logic signed [15:0] s_coefficient,
    output logic m_valid, input logic m_ready, output logic signed [15:0] m_residual,
    output logic [2:0] m_x, output logic [2:0] m_y, output logic m_block_last
);
    hevc_transform8_core #(.INVERSE(1'b1)) core (
        .clk, .rst_n, .s_valid, .s_ready, .s_data(s_coefficient),
        .m_valid, .m_ready, .m_data(m_residual), .m_x, .m_y, .m_block_last
    );
endmodule
