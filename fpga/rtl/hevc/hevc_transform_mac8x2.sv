module hevc_transform_mac8x2 (
    input  logic signed [127:0] samples_a,
    input  logic signed [63:0]  coefficients_a,
    output logic signed [31:0]  sum_a,
    input  logic signed [127:0] samples_b,
    input  logic signed [63:0]  coefficients_b,
    output logic signed [31:0]  sum_b
);
    logic signed [15:0] sample_a, sample_b;
    logic signed [7:0] coefficient_a, coefficient_b;
    logic signed [23:0] product_a, product_b;
    integer lane;

    always_comb begin
        sum_a = '0;
        sum_b = '0;
        sample_a = '0;
        sample_b = '0;
        coefficient_a = '0;
        coefficient_b = '0;
        product_a = '0;
        product_b = '0;
        for (lane = 0; lane < 8; lane = lane + 1) begin
            sample_a = samples_a[lane * 16 +: 16];
            sample_b = samples_b[lane * 16 +: 16];
            coefficient_a = coefficients_a[lane * 8 +: 8];
            coefficient_b = coefficients_b[lane * 8 +: 8];
            product_a = sample_a * coefficient_a;
            product_b = sample_b * coefficient_b;
            sum_a = sum_a + {{8{product_a[23]}}, product_a};
            sum_b = sum_b + {{8{product_b[23]}}, product_b};
        end
    end
endmodule
