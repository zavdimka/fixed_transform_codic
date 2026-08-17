module hevc_transform_mac8x2 (
    input  logic signed [127:0] samples_a,
    input  logic signed [63:0]  coefficients_a,
    output logic signed [31:0]  sum_a,
    input  logic signed [127:0] samples_b,
    input  logic signed [63:0]  coefficients_b,
    output logic signed [31:0]  sum_b
);
    logic signed [23:0] products_a [0:7];
    logic signed [23:0] products_b [0:7];
    logic signed [31:0] sum_level1_a [0:3];
    logic signed [31:0] sum_level1_b [0:3];
    logic signed [31:0] sum_level2_a [0:1];
    logic signed [31:0] sum_level2_b [0:1];

    genvar lane;
    generate
        for (lane = 0; lane < 8; lane = lane + 1) begin : products
            assign products_a[lane] =
                $signed(samples_a[lane * 16 +: 16]) *
                $signed(coefficients_a[lane * 8 +: 8]);
            assign products_b[lane] =
                $signed(samples_b[lane * 16 +: 16]) *
                $signed(coefficients_b[lane * 8 +: 8]);
        end

        for (lane = 0; lane < 4; lane = lane + 1) begin : level1
            assign sum_level1_a[lane] =
                {{8{products_a[2*lane][23]}}, products_a[2*lane]} +
                {{8{products_a[2*lane+1][23]}}, products_a[2*lane+1]};
            assign sum_level1_b[lane] =
                {{8{products_b[2*lane][23]}}, products_b[2*lane]} +
                {{8{products_b[2*lane+1][23]}}, products_b[2*lane+1]};
        end

        for (lane = 0; lane < 2; lane = lane + 1) begin : level2
            assign sum_level2_a[lane] =
                sum_level1_a[2*lane] + sum_level1_a[2*lane+1];
            assign sum_level2_b[lane] =
                sum_level1_b[2*lane] + sum_level1_b[2*lane+1];
        end
    endgenerate

    assign sum_a = sum_level2_a[0] + sum_level2_a[1];
    assign sum_b = sum_level2_b[0] + sum_level2_b[1];
endmodule
