module hevc_transform_mac16 (
    input  logic clk,
    input  logic enable,
    input  logic signed [255:0] samples,
    input  logic signed [127:0] coefficients,
    output logic signed [383:0] products
);
    genvar lane;
    generate
        for (lane = 0; lane < 16; lane = lane + 1) begin : product_lanes
            always_ff @(posedge clk) begin
                if (enable)
                    products[lane * 24 +: 24] <=
                        $signed(samples[lane * 16 +: 16]) *
                        $signed(coefficients[lane * 8 +: 8]);
            end
        end
    endgenerate
endmodule
