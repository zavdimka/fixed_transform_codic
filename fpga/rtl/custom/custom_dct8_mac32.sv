module custom_dct8_mac32 (
    input  logic                       clk,
    input  logic                       enable,
    input  logic signed [127:0]        samples_a,
    input  logic signed [111:0]        coefficients_0,
    input  logic signed [111:0]        coefficients_1,
    output logic signed [239:0]        products_a0,
    output logic signed [239:0]        products_a1,
    input  logic signed [127:0]        samples_b,
    output logic signed [239:0]        products_b0,
    output logic signed [239:0]        products_b1
);
    genvar lane;
    generate
        for (lane = 0; lane < 8; lane = lane + 1) begin : multiply
            always_ff @(posedge clk) begin
                if (enable) begin
                    products_a0[lane * 30 +: 30] <=
                        $signed(samples_a[lane * 16 +: 16]) *
                        $signed(coefficients_0[lane * 14 +: 14]);
                    products_a1[lane * 30 +: 30] <=
                        $signed(samples_a[lane * 16 +: 16]) *
                        $signed(coefficients_1[lane * 14 +: 14]);
                    products_b0[lane * 30 +: 30] <=
                        $signed(samples_b[lane * 16 +: 16]) *
                        $signed(coefficients_0[lane * 14 +: 14]);
                    products_b1[lane * 30 +: 30] <=
                        $signed(samples_b[lane * 16 +: 16]) *
                        $signed(coefficients_1[lane * 14 +: 14]);
                end
            end
        end
    endgenerate
endmodule
