module receiver_iht8_1d_pipeline (
    input  logic                 clk,
    input  logic                 rst_n,
    input  logic                 input_valid,
    input  logic [3:0]           input_tag,
    input  logic signed [191:0]  input_values,
    output logic                 output_valid,
    output logic [3:0]           output_tag,
    output logic signed [191:0]  output_values
);
    // Four registered add/shift stages implement the H.264-style inverse
    // integer transform.  No stage contains more than one wide addition.
    logic s1_valid, s2_valid, s3_valid;
    logic [3:0] s1_tag, s2_tag, s3_tag;
    // 24 bits cover two worst-case transform passes with margin.
    logic signed [23:0] s1 [0:15];
    logic signed [23:0] s2 [0:7];
    logic signed [23:0] s3 [0:7];
    integer index;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            s1_valid <= 1'b0;
            s2_valid <= 1'b0;
            s3_valid <= 1'b0;
            output_valid <= 1'b0;
            s1_tag <= 4'd0;
            s2_tag <= 4'd0;
            s3_tag <= 4'd0;
            output_tag <= 4'd0;
            output_values <= '0;
            for (index = 0; index < 16; index = index + 1)
                s1[index] <= 24'sd0;
            for (index = 0; index < 8; index = index + 1) begin
                s2[index] <= 24'sd0;
                s3[index] <= 24'sd0;
            end
        end else begin
            s1_valid <= input_valid;
            s2_valid <= s1_valid;
            s3_valid <= s2_valid;
            output_valid <= s3_valid;
            s1_tag <= input_tag;
            s2_tag <= s1_tag;
            s3_tag <= s2_tag;
            output_tag <= s3_tag;

            if (input_valid) begin
                // Even terms and paired odd partials.  Each assignment is one
                // add/subtract after wiring-only arithmetic shifts.
                s1[0] <= $signed(input_values[0*24 +: 24])
                       + $signed(input_values[4*24 +: 24]);
                s1[1] <= $signed(input_values[0*24 +: 24])
                       - $signed(input_values[4*24 +: 24]);
                s1[2] <= ($signed(input_values[2*24 +: 24]) >>> 1)
                       - $signed(input_values[6*24 +: 24]);
                s1[3] <= $signed(input_values[2*24 +: 24])
                       + ($signed(input_values[6*24 +: 24]) >>> 1);
                s1[4] <= -$signed(input_values[3*24 +: 24])
                       + $signed(input_values[5*24 +: 24]);
                s1[5] <= -$signed(input_values[7*24 +: 24])
                       - ($signed(input_values[7*24 +: 24]) >>> 1);
                s1[6] <= $signed(input_values[1*24 +: 24])
                       + $signed(input_values[7*24 +: 24]);
                s1[7] <= -$signed(input_values[3*24 +: 24])
                       - ($signed(input_values[3*24 +: 24]) >>> 1);
                s1[8] <= -$signed(input_values[1*24 +: 24])
                       + $signed(input_values[7*24 +: 24]);
                s1[9] <= $signed(input_values[5*24 +: 24])
                       + ($signed(input_values[5*24 +: 24]) >>> 1);
                s1[10] <= $signed(input_values[3*24 +: 24])
                        + $signed(input_values[5*24 +: 24]);
                s1[11] <= $signed(input_values[1*24 +: 24])
                        + ($signed(input_values[1*24 +: 24]) >>> 1);
                for (index = 12; index < 16; index = index + 1)
                    s1[index] <= 24'sd0;
            end

            if (s1_valid) begin
                s2[0] <= s1[0];
                s2[1] <= s1[1];
                s2[2] <= s1[2];
                s2[3] <= s1[3];
                s2[4] <= s1[4] + s1[5];
                s2[5] <= s1[6] + s1[7];
                s2[6] <= s1[8] + s1[9];
                s2[7] <= s1[10] + s1[11];
            end

            if (s2_valid) begin
                s3[0] <= s2[0] + s2[3];
                s3[2] <= s2[1] + s2[2];
                s3[4] <= s2[1] - s2[2];
                s3[6] <= s2[0] - s2[3];
                s3[1] <= s2[4] + (s2[7] >>> 2);
                s3[3] <= s2[5] + (s2[6] >>> 2);
                s3[5] <= (s2[5] >>> 2) - s2[6];
                s3[7] <= s2[7] - (s2[4] >>> 2);
            end

            if (s3_valid) begin
                output_values[0*24 +: 24] <= s3[0] + s3[7];
                output_values[1*24 +: 24] <= s3[2] + s3[5];
                output_values[2*24 +: 24] <= s3[4] + s3[3];
                output_values[3*24 +: 24] <= s3[6] + s3[1];
                output_values[4*24 +: 24] <= s3[6] - s3[1];
                output_values[5*24 +: 24] <= s3[4] - s3[3];
                output_values[6*24 +: 24] <= s3[2] - s3[5];
                output_values[7*24 +: 24] <= s3[0] - s3[7];
            end
        end
    end
endmodule
