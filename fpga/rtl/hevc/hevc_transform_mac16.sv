module hevc_transform_mac16 (
    input  logic signed [255:0] samples,
    input  logic signed [127:0] coefficients,
    output logic signed [31:0]  sum
);
    logic signed [15:0] sample;
    logic signed [7:0] coefficient;
    logic signed [23:0] product;
    integer lane;

    always_comb begin
        sum = '0;
        sample = '0;
        coefficient = '0;
        product = '0;
        for (lane = 0; lane < 16; lane = lane + 1) begin
            sample = samples[lane * 16 +: 16];
            coefficient = coefficients[lane * 8 +: 8];
            product = sample * coefficient;
            sum = sum + {{8{product[23]}}, product};
        end
    end
endmodule
