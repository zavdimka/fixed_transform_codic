module hevc_shared_quant_mac (
    input  logic [15:0]        coefficient_absolute,
    input  logic [14:0]        quant_scale,
    output logic [30:0]        quant_product,
    input  logic signed [15:0] quantized,
    input  logic [6:0]         inverse_scale,
    output logic signed [23:0] dequant_product
);
    always_comb begin
        quant_product = coefficient_absolute * quant_scale;
        dequant_product = quantized * $signed({1'b0, inverse_scale});
    end
endmodule
