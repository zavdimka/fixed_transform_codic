module hevc_shared_quant_mac (
    input  logic               clk,
    input  logic               inverse_enable,
    input  logic [15:0]        coefficient_absolute,
    input  logic [14:0]        quant_scale,
    output logic [30:0]        quant_product,
    input  logic signed [15:0] quantized,
    input  logic [6:0]         inverse_scale,
    output logic signed [23:0] dequant_product
);
    always_comb
        quant_product = coefficient_absolute * quant_scale;

    // Keep the inverse product in the DSP output register.  The enable is the
    // elastic-pipeline advance, so the product remains aligned with metadata
    // while downstream applies backpressure.
    always_ff @(posedge clk) begin
        if (inverse_enable)
            dequant_product <= quantized * $signed({1'b0, inverse_scale});
    end
endmodule
