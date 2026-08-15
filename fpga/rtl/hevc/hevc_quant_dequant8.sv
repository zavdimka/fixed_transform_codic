module hevc_quant_dequant8 (
    input logic clk, input logic rst_n,
    input logic s_valid, output logic s_ready, input logic signed [15:0] s_coefficient,
    input logic [3:0] s_qp_per, input logic [2:0] s_qp_rem,
    input logic [2:0] s_x, input logic [2:0] s_y, input logic s_block_last,
    output logic m_valid, input logic m_ready,
    output logic signed [15:0] m_quantized, output logic signed [15:0] m_dequantized,
    output logic m_nonzero, output logic m_qp_error,
    output logic [2:0] m_x, output logic [2:0] m_y, output logic m_block_last
);
    logic [14:0] qscale;
    logic [6:0] iqscale;
    logic [15:0] magnitude;
    logic [30:0] qproduct, qsum;
    logic [4:0] qshift;
    logic signed [15:0] quantized_value;
    logic signed [31:0] dequant_product, dequant_rounded;
    logic signed [15:0] dequantized_value;

    function automatic logic [14:0] quant_scale(input logic [2:0] r);
        case (r) 0:quant_scale=26214;1:quant_scale=23302;2:quant_scale=20560;
                 3:quant_scale=18396;4:quant_scale=16384;default:quant_scale=14564; endcase
    endfunction
    function automatic logic [6:0] inverse_scale(input logic [2:0] r);
        case (r) 0:inverse_scale=40;1:inverse_scale=45;2:inverse_scale=51;
                 3:inverse_scale=57;4:inverse_scale=64;default:inverse_scale=72; endcase
    endfunction

    assign s_ready = !m_valid || m_ready;
    always_comb begin
        qscale = quant_scale(s_qp_rem);
        iqscale = inverse_scale(s_qp_rem);
        magnitude = s_coefficient[15] ? (~$unsigned(s_coefficient) + 1'b1)
                                      : $unsigned(s_coefficient);
        qshift = 5'd18 + s_qp_per;
        qproduct = magnitude * qscale;
        qsum = qproduct + (31'd171 << (5'd9 + s_qp_per));
        quantized_value = s_coefficient[15]
            ? -$signed(16'(qsum >> qshift)) : $signed(16'(qsum >> qshift));
        dequant_product = quantized_value * $signed({1'b0, iqscale});
        dequant_rounded = ((dequant_product <<< s_qp_per) + 2) >>> 2;
        if (dequant_rounded > 32767) dequantized_value = 32767;
        else if (dequant_rounded < -32768) dequantized_value = -32768;
        else dequantized_value = dequant_rounded[15:0];
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            m_valid <= 1'b0; m_quantized <= '0; m_dequantized <= '0;
            m_nonzero <= 1'b0; m_qp_error <= 1'b0;
            m_x <= '0; m_y <= '0; m_block_last <= 1'b0;
        end else if (s_ready) begin
            m_valid <= s_valid;
            if (s_valid) begin
                m_quantized <= quantized_value;
                m_dequantized <= dequantized_value;
                m_nonzero <= quantized_value != 0;
                m_qp_error <= (s_qp_rem > 5) || (s_qp_per > 8) ||
                              ((s_qp_per == 8) && (s_qp_rem > 3));
                m_x <= s_x; m_y <= s_y; m_block_last <= s_block_last;
            end
        end
    end
endmodule
