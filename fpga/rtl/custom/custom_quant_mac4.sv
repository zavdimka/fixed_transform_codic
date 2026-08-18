module custom_quant_mac4 (
    input  logic         clk,
    input  logic         enable,
    input  logic [15:0]  operand_a0,
    input  logic [15:0]  operand_a1,
    input  logic [15:0]  operand_b0,
    input  logic [15:0]  operand_b1,
    input  logic [13:0]  factor_0,
    input  logic [13:0]  factor_1,
    output logic [29:0]  product_a0,
    output logic [29:0]  product_a1,
    output logic [29:0]  product_b0,
    output logic [29:0]  product_b1
);
    always_ff @(posedge clk) begin
        if (enable) begin
            product_a0 <= operand_a0 * factor_0;
            product_a1 <= operand_a1 * factor_1;
            product_b0 <= operand_b0 * factor_0;
            product_b1 <= operand_b1 * factor_1;
        end
    end
endmodule
