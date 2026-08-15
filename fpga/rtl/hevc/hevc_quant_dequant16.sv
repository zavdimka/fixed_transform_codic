module hevc_quant_dequant16 (
    input  logic               clk,
    input  logic               rst_n,

    input  logic               s_valid,
    output logic               s_ready,
    input  logic signed [15:0] s_coefficient,
    input  logic [3:0]         s_qp_per,
    input  logic [2:0]         s_qp_rem,
    input  logic [3:0]         s_x,
    input  logic [3:0]         s_y,
    input  logic               s_block_last,

    output logic               m_valid,
    input  logic               m_ready,
    output logic signed [15:0] m_quantized,
    output logic signed [15:0] m_dequantized,
    output logic               m_nonzero,
    output logic               m_qp_error,
    output logic [3:0]         m_x,
    output logic [3:0]         m_y,
    output logic               m_block_last
);
    logic stage1_valid;
    logic stage1_ready;
    logic stage2_ready;
    logic signed [15:0] stage1_quantized;
    logic [3:0] stage1_qp_per;
    logic [2:0] stage1_qp_rem;
    logic [3:0] stage1_x;
    logic [3:0] stage1_y;
    logic stage1_block_last;
    logic stage1_qp_error;

    logic [14:0] quant_scale_value;
    logic [6:0] inverse_scale_value;
    logic [15:0] coefficient_absolute;
    logic [30:0] quant_product;
    logic [4:0] quant_shift;
    logic [4:0] quant_offset_shift;
    logic [30:0] quant_offset;
    logic [30:0] quant_sum;
    logic [15:0] quant_magnitude;
    logic signed [15:0] quantized_value;
    logic qp_error_value;

    logic signed [23:0] dequant_product_base;
    logic signed [31:0] dequant_scaled;
    logic signed [31:0] dequant_rounded;
    logic signed [15:0] dequantized_value;

    function automatic logic [14:0] quant_scale(
        input logic [2:0] qp_rem
    );
        case (qp_rem)
            3'd0: quant_scale = 15'd26214;
            3'd1: quant_scale = 15'd23302;
            3'd2: quant_scale = 15'd20560;
            3'd3: quant_scale = 15'd18396;
            3'd4: quant_scale = 15'd16384;
            3'd5: quant_scale = 15'd14564;
            default: quant_scale = 15'd26214;
        endcase
    endfunction

    function automatic logic [6:0] inverse_quant_scale(
        input logic [2:0] qp_rem
    );
        case (qp_rem)
            3'd0: inverse_quant_scale = 7'd40;
            3'd1: inverse_quant_scale = 7'd45;
            3'd2: inverse_quant_scale = 7'd51;
            3'd3: inverse_quant_scale = 7'd57;
            3'd4: inverse_quant_scale = 7'd64;
            3'd5: inverse_quant_scale = 7'd72;
            default: inverse_quant_scale = 7'd40;
        endcase
    endfunction

    assign stage2_ready = !m_valid || m_ready;
    assign stage1_ready = !stage1_valid || stage2_ready;
    assign s_ready = stage1_ready;

    always_comb begin
        quant_scale_value = quant_scale(s_qp_rem);
        coefficient_absolute = s_coefficient[15]
            ? (~$unsigned(s_coefficient) + 16'd1)
            : $unsigned(s_coefficient);
        quant_product = coefficient_absolute * quant_scale_value;
        quant_shift = 5'd17 + {1'b0, s_qp_per};
        quant_offset_shift = 5'd8 + {1'b0, s_qp_per};
        quant_offset = 31'd171 << quant_offset_shift;
        quant_sum = quant_product + quant_offset;
        quant_magnitude = 16'(quant_sum >> quant_shift);
        quantized_value = s_coefficient[15]
            ? -$signed(quant_magnitude) : $signed(quant_magnitude);
        qp_error_value = (s_qp_rem > 5) || (s_qp_per > 8) ||
                         ((s_qp_per == 8) && (s_qp_rem > 3));
    end

    always_comb begin
        inverse_scale_value = inverse_quant_scale(stage1_qp_rem);
        dequant_product_base = stage1_quantized
                             * $signed({1'b0, inverse_scale_value});
        dequant_scaled = $signed({{8{dequant_product_base[23]}},
                                  dequant_product_base})
                       <<< stage1_qp_per;
        dequant_rounded = (dequant_scaled + 32'sd4) >>> 3;
        if (dequant_rounded > 32767) begin
            dequantized_value = 16'sd32767;
        end else if (dequant_rounded < -32768) begin
            dequantized_value = -16'sd32768;
        end else begin
            dequantized_value = dequant_rounded[15:0];
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            stage1_valid      <= 1'b0;
            stage1_quantized  <= '0;
            stage1_qp_per     <= '0;
            stage1_qp_rem     <= '0;
            stage1_x          <= '0;
            stage1_y          <= '0;
            stage1_block_last <= 1'b0;
            stage1_qp_error   <= 1'b0;
            m_valid           <= 1'b0;
            m_quantized       <= '0;
            m_dequantized     <= '0;
            m_nonzero         <= 1'b0;
            m_qp_error        <= 1'b0;
            m_x               <= '0;
            m_y               <= '0;
            m_block_last      <= 1'b0;
        end else begin
            if (stage2_ready) begin
                m_valid <= stage1_valid;
                if (stage1_valid) begin
                    m_quantized   <= stage1_quantized;
                    m_dequantized <= dequantized_value;
                    m_nonzero     <= stage1_quantized != 0;
                    m_qp_error    <= stage1_qp_error;
                    m_x           <= stage1_x;
                    m_y           <= stage1_y;
                    m_block_last  <= stage1_block_last;
                end
            end

            if (stage1_ready) begin
                stage1_valid <= s_valid;
                if (s_valid) begin
                    stage1_quantized  <= quantized_value;
                    stage1_qp_per     <= s_qp_per;
                    stage1_qp_rem     <= s_qp_rem;
                    stage1_x          <= s_x;
                    stage1_y          <= s_y;
                    stage1_block_last <= s_block_last;
                    stage1_qp_error   <= qp_error_value;
                end
            end
        end
    end
endmodule
