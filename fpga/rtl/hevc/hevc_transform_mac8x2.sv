module hevc_transform_mac8x2 (
    input  logic clk,
    input  logic enable_a,
    input  logic signed [127:0] samples_a,
    input  logic signed [63:0]  coefficients_a,
    output logic signed [191:0] products_a,
    input  logic enable_b,
    input  logic signed [127:0] samples_b,
    input  logic signed [63:0]  coefficients_b,
    output logic signed [191:0] products_b
);
    genvar lane;
    generate
        for (lane = 0; lane < 8; lane = lane + 1) begin : products
            always_ff @(posedge clk) begin
                if (enable_a)
                    products_a[lane * 24 +: 24] <=
                        $signed(samples_a[lane * 16 +: 16]) *
                        $signed(coefficients_a[lane * 8 +: 8]);
                if (enable_b)
                    products_b[lane * 24 +: 24] <=
                        $signed(samples_b[lane * 16 +: 16]) *
                        $signed(coefficients_b[lane * 8 +: 8]);
            end
        end
    endgenerate
endmodule
