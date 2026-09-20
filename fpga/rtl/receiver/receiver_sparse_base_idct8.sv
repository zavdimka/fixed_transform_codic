module receiver_sparse_base_idct8 (
    input  logic         clk,
    input  logic         rst_n,

    input  logic         command_valid,
    output logic         command_ready,
    input  logic [6:0]   command_ctu_index,
    input  logic [2:0]   command_block_index,
    input  logic [1:0]   command_plane,
    input  logic [1:0]   command_mode,
    input  logic [7:0]   command_quality,
    input  logic [71:0]  command_coefficients,

    output logic         pixel_valid,
    input  logic         pixel_ready,
    output logic [5:0]   pixel_index,
    output logic signed [15:0] pixel_residual,
    output logic         pixel_last,
    output logic [6:0]   pixel_ctu_index,
    output logic [2:0]   pixel_block_index,
    output logic [1:0]   pixel_plane,
    output logic [1:0]   pixel_mode,
    output logic         done,
    output logic         busy,
    output logic         saturated
);
    localparam logic [2:0] S_IDLE          = 3'd0;
    localparam logic [2:0] S_DEQUANT       = 3'd1;
    localparam logic [2:0] S_DEQUANT_DRAIN = 3'd2;
    localparam logic [2:0] S_PASS1         = 3'd3;
    localparam logic [2:0] S_PASS1_DRAIN   = 3'd4;
    localparam logic [2:0] S_PASS2         = 3'd5;
    localparam logic [2:0] S_PASS2_DRAIN   = 3'd6;

    logic [2:0] state;
    logic [6:0] issue_index;
    logic [6:0] active_ctu_index;
    logic [2:0] active_block_index;
    logic [1:0] active_plane, active_mode;
    logic [7:0] active_quality;
    logic signed [11:0] quantized [0:5];
    logic signed [15:0] dequantized [0:5];
    // Keep the three retained vertical-frequency rows separate.  Besides
    // matching the transform structure, this avoids a dynamic x*3 address
    // and the resulting wide register mux in the FPGA fabric.
    logic signed [17:0] intermediate0 [0:7];
    logic signed [17:0] intermediate1 [0:7];
    logic signed [17:0] intermediate2 [0:7];

    logic issue_valid;
    logic issue_pass1;
    logic [5:0] issue_tag;
    logic dsp_issue_valid, dsp_issue_pass1;
    logic [5:0] dsp_issue_tag;
    logic mul_valid, mul_pass1;
    logic [5:0] mul_tag;
    logic sum_valid, sum_pass1;
    logic [5:0] sum_tag;
    logic magnitude_valid, magnitude_pass1;
    logic [5:0] magnitude_tag;
    logic magnitude_negative0, magnitude_negative1, magnitude_negative2;
    logic [33:0] magnitude_register0;
    logic [33:0] magnitude_register1;
    logic [33:0] magnitude_register2;
    logic rounded_valid, rounded_pass1;
    logic [5:0] rounded_tag;
    logic [20:0] rounded_register0;
    logic [20:0] rounded_register1;
    logic [20:0] rounded_register2;
    logic rounded_negative0, rounded_negative1, rounded_negative2;
    logic signed [33:0] sum_register0;
    logic signed [33:0] sum_register1;
    logic signed [33:0] sum_register2;
    logic saturation_sticky;
    logic saturation_dequant_event;
    logic saturation_round_event;

    logic signed [17:0] operand_a [0:5];
    logic signed [13:0] operand_b [0:5];
    logic signed [17:0] dsp_operand_a [0:5];
    logic signed [13:0] dsp_operand_b [0:5];
    logic signed [31:0] product [0:5];
    logic signed [33:0] next_sum0, next_sum1, next_sum2;
    wire pipeline_advance = !pixel_valid || pixel_ready;
    wire command_fire = command_valid && command_ready;
    wire output_fire = pixel_valid && pixel_ready;

    assign command_ready = (state == S_IDLE);
    assign busy = (state != S_IDLE);

    function automatic logic signed [13:0] basis_value(
        input logic [1:0] frequency,
        input logic [2:0] position
    );
        begin
            case (frequency)
                2'd0: basis_value = 14'sd5793;
                2'd1: begin
                    case (position)
                        0: basis_value = 14'sd8035;
                        1: basis_value = 14'sd6811;
                        2: basis_value = 14'sd4551;
                        3: basis_value = 14'sd1598;
                        4: basis_value = -14'sd1598;
                        5: basis_value = -14'sd4551;
                        6: basis_value = -14'sd6811;
                        default: basis_value = -14'sd8035;
                    endcase
                end
                default: begin
                    case (position)
                        0: basis_value = 14'sd7568;
                        1: basis_value = 14'sd3135;
                        2: basis_value = -14'sd3135;
                        3: basis_value = -14'sd7568;
                        4: basis_value = -14'sd7568;
                        5: basis_value = -14'sd3135;
                        6: basis_value = 14'sd3135;
                        default: basis_value = 14'sd7568;
                    endcase
                end
            endcase
        end
    endfunction

    // The receiver profile freezes the two transmitted quality presets. Base
    // coefficients use the quality+2 tables, exactly as layered_quant_tables.
    function automatic logic [7:0] quant_divisor(
        input logic quality24,
        input logic chroma,
        input logic [2:0] coefficient_index
    );
        begin
            if (quality24 && !chroma) begin
                case (coefficient_index)
                    0: quant_divisor = 8'd31;
                    1: quant_divisor = 8'd21;
                    2: quant_divisor = 8'd23;
                    3: quant_divisor = 8'd27;
                    4: quant_divisor = 8'd23;
                    default: quant_divisor = 8'd19;
                endcase
            end else if (quality24) begin
                case (coefficient_index)
                    0: quant_divisor = 8'd33;
                    1: quant_divisor = 8'd35;
                    2: quant_divisor = 8'd35;
                    3: quant_divisor = 8'd50;
                    4: quant_divisor = 8'd44;
                    default: quant_divisor = 8'd50;
                endcase
            end else if (!chroma) begin
                case (coefficient_index)
                    0: quant_divisor = 8'd36;
                    1: quant_divisor = 8'd25;
                    2: quant_divisor = 8'd27;
                    3: quant_divisor = 8'd32;
                    4: quant_divisor = 8'd27;
                    default: quant_divisor = 8'd23;
                endcase
            end else begin
                case (coefficient_index)
                    0: quant_divisor = 8'd39;
                    1: quant_divisor = 8'd41;
                    2: quant_divisor = 8'd41;
                    3: quant_divisor = 8'd60;
                    4: quant_divisor = 8'd53;
                    default: quant_divisor = 8'd60;
                endcase
            end
        end
    endfunction

    function automatic logic [20:0] round_magnitude_q14(
        input logic [33:0] magnitude
    );
        begin
            // Rounded magnitude is kept unsigned; carrying the sign beside it
            // avoids a second wide two's-complement carry chain in this stage.
            round_magnitude_q14 = {1'b0, magnitude[33:14]}
                                + {20'd0, magnitude[13]};
        end
    endfunction
    function automatic logic signed [15:0] clip16(
        input logic signed [33:0] value
    );
        begin
            if (value > 34'sd32767)
                clip16 = 16'sd32767;
            else if (value < -34'sd32768)
                clip16 = -16'sd32768;
            else
                clip16 = value[15:0];
        end
    endfunction

    function automatic logic signed [17:0] clip18(
        input logic signed [33:0] value
    );
        begin
            if (value > 34'sd131071)
                clip18 = 18'sd131071;
            else if (value < -34'sd131072)
                clip18 = -18'sd131072;
            else
                clip18 = value[17:0];
        end
    endfunction

    function automatic logic signed [15:0] clip16_signmag(
        input logic [20:0] magnitude,
        input logic negative
    );
        begin
            if ((!negative && (magnitude > 21'd32767)))
                clip16_signmag = 16'sd32767;
            else if (negative && (magnitude > 21'd32768))
                clip16_signmag = -16'sd32768;
            else if (negative)
                clip16_signmag = -(magnitude[15:0]);
            else
                clip16_signmag = (magnitude[15:0]);
        end
    endfunction

    function automatic logic signed [17:0] clip18_signmag(
        input logic [20:0] magnitude,
        input logic negative
    );
        begin
            if ((!negative && (magnitude > 21'd131071)))
                clip18_signmag = 18'sd131071;
            else if (negative && (magnitude > 21'd131072))
                clip18_signmag = -18'sd131072;
            else if (negative)
                clip18_signmag = -(magnitude[17:0]);
            else
                clip18_signmag = (magnitude[17:0]);
        end
    endfunction

    wire [20:0] rounded_sum0 = round_magnitude_q14(magnitude_register0);
    wire signed [20:0] rounded_sum1 = round_magnitude_q14(magnitude_register1);
    wire signed [20:0] rounded_sum2 = round_magnitude_q14(magnitude_register2);
    // Dequant clipping still happens in clip16 below. The wide six-lane
    // overflow OR fed only the sticky diagnostic flag and formed a DSP-to-FF
    // critical path, so keep it out of the performance build.
    wire dequant_saturation_now = 1'b0;    wire round_saturation_now = rounded_valid
        && ((!rounded_pass1
             && ((!rounded_negative0 && (rounded_register0 > 21'd32767))
                 || (rounded_negative0 && (rounded_register0 > 21'd32768))))
            || (rounded_pass1
                && ((!rounded_negative0 && (rounded_register0 > 21'd131071))
                    || (rounded_negative0 && (rounded_register0 > 21'd131072))
                    || (!rounded_negative1 && (rounded_register1 > 21'd131071))
                    || (rounded_negative1 && (rounded_register1 > 21'd131072))
                    || (!rounded_negative2 && (rounded_register2 > 21'd131071))
                    || (rounded_negative2 && (rounded_register2 > 21'd131072)))));
    assign saturated = saturation_sticky
                     | saturation_dequant_event
                     | saturation_round_event;

    integer lane;
    always_comb begin
        issue_valid = 1'b0;
        issue_pass1 = 1'b0;
        issue_tag = issue_index[5:0];
        for (lane = 0; lane < 6; lane = lane + 1) begin
            operand_a[lane] = 18'sd0;
            operand_b[lane] = 14'sd0;
        end

        if (state == S_DEQUANT) begin
            issue_valid = 1'b1;
            for (lane = 0; lane < 6; lane = lane + 1) begin
                operand_a[lane] = {{6{quantized[lane][11]}}, quantized[lane]};
                operand_b[lane] = $signed({6'd0, quant_divisor(
                    active_quality == 8'd24, active_plane != 0, 3'(lane)
                )});
            end
        end else if (state == S_PASS1) begin
            issue_valid = 1'b1;
            issue_pass1 = 1'b1;
            operand_a[0] = {{2{dequantized[0][15]}}, dequantized[0]};
            operand_a[1] = {{2{dequantized[2][15]}}, dequantized[2]};
            operand_a[2] = {{2{dequantized[3][15]}}, dequantized[3]};
            operand_a[3] = {{2{dequantized[1][15]}}, dequantized[1]};
            operand_a[4] = {{2{dequantized[4][15]}}, dequantized[4]};
            operand_a[5] = {{2{dequantized[5][15]}}, dequantized[5]};
            operand_b[0] = basis_value(0, issue_index[2:0]);
            operand_b[1] = basis_value(1, issue_index[2:0]);
            operand_b[2] = basis_value(2, issue_index[2:0]);
            operand_b[3] = basis_value(0, issue_index[2:0]);
            operand_b[4] = basis_value(1, issue_index[2:0]);
            operand_b[5] = basis_value(0, issue_index[2:0]);
        end else if (state == S_PASS2) begin
            issue_valid = 1'b1;
            operand_a[0] = intermediate0[issue_index[5:3]];
            operand_a[1] = intermediate1[issue_index[5:3]];
            operand_a[2] = intermediate2[issue_index[5:3]];
            operand_b[0] = basis_value(0, issue_index[2:0]);
            operand_b[1] = basis_value(1, issue_index[2:0]);
            operand_b[2] = basis_value(2, issue_index[2:0]);
        end

        next_sum0 = {{2{product[0][31]}}, product[0]}
                  + {{2{product[1][31]}}, product[1]}
                  + {{2{product[2][31]}}, product[2]};
        next_sum1 = {{2{product[3][31]}}, product[3]}
                  + {{2{product[4][31]}}, product[4]};
        next_sum2 = {{2{product[5][31]}}, product[5]};
    end

    genvar multiplier_lane;
    generate
        for (multiplier_lane = 0; multiplier_lane < 6;
             multiplier_lane = multiplier_lane + 1) begin : multipliers
            always_ff @(posedge clk) begin
                if (pipeline_advance && dsp_issue_valid)
                    product[multiplier_lane] <=
                        dsp_operand_a[multiplier_lane]
                        * dsp_operand_b[multiplier_lane];
            end
        end
    endgenerate

    integer value_index;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE;
            issue_index <= 7'd0;
            active_ctu_index <= 7'd0;
            active_block_index <= 3'd0;
            active_plane <= 2'd0;
            active_mode <= 2'd0;
            active_quality <= 8'd0;
            dsp_issue_valid <= 1'b0;
            dsp_issue_pass1 <= 1'b0;
            dsp_issue_tag <= 6'd0;
            mul_valid <= 1'b0;
            mul_pass1 <= 1'b0;
            mul_tag <= 6'd0;
            sum_valid <= 1'b0;
            sum_pass1 <= 1'b0;
            sum_tag <= 6'd0;
            magnitude_valid <= 1'b0;
            magnitude_pass1 <= 1'b0;
            magnitude_tag <= 6'd0;
            magnitude_negative0 <= 1'b0;
            magnitude_negative1 <= 1'b0;
            magnitude_negative2 <= 1'b0;
            magnitude_register0 <= 34'd0;
            magnitude_register1 <= 34'd0;
            magnitude_register2 <= 34'd0;
            rounded_valid <= 1'b0;
            rounded_pass1 <= 1'b0;
            rounded_tag <= 6'd0;
            rounded_register0 <= 21'd0;
            rounded_register1 <= 21'd0;
            rounded_register2 <= 21'd0;
            rounded_negative0 <= 1'b0;
            rounded_negative1 <= 1'b0;
            rounded_negative2 <= 1'b0;
            sum_register0 <= 34'sd0;
            sum_register1 <= 34'sd0;
            sum_register2 <= 34'sd0;
            pixel_valid <= 1'b0;
            pixel_index <= 6'd0;
            pixel_residual <= 16'sd0;
            pixel_last <= 1'b0;
            pixel_ctu_index <= 7'd0;
            pixel_block_index <= 3'd0;
            pixel_plane <= 2'd0;
            pixel_mode <= 2'd0;
            done <= 1'b0;
            saturation_sticky <= 1'b0;
            saturation_dequant_event <= 1'b0;
            saturation_round_event <= 1'b0;
            for (value_index = 0; value_index < 6;
                 value_index = value_index + 1) begin
                quantized[value_index] <= 12'sd0;
                dequantized[value_index] <= 16'sd0;
                dsp_operand_a[value_index] <= 18'sd0;
                dsp_operand_b[value_index] <= 14'sd0;
            end
            for (value_index = 0; value_index < 8;
                 value_index = value_index + 1) begin
                intermediate0[value_index] <= 18'sd0;
                intermediate1[value_index] <= 18'sd0;
                intermediate2[value_index] <= 18'sd0;
            end
        end else begin
            done <= 1'b0;

            if (command_fire) begin
                active_ctu_index <= command_ctu_index;
                active_block_index <= command_block_index;
                active_plane <= command_plane;
                active_mode <= command_mode;
                active_quality <= command_quality;
                for (value_index = 0; value_index < 6;
                     value_index = value_index + 1)
                    quantized[value_index] <= $signed(
                        command_coefficients[value_index * 12 +: 12]
                    );
                state <= S_DEQUANT;
                issue_index <= 7'd0;
                dsp_issue_valid <= 1'b0;
                mul_valid <= 1'b0;
                sum_valid <= 1'b0;
                magnitude_valid <= 1'b0;
                rounded_valid <= 1'b0;
                pixel_valid <= 1'b0;
                saturation_sticky <= 1'b0;
                saturation_dequant_event <= 1'b0;
                saturation_round_event <= 1'b0;
            end

            if (pipeline_advance) begin
                saturation_sticky <= command_fire ? 1'b0
                    : (saturation_sticky | saturation_dequant_event
                       | saturation_round_event);
                saturation_dequant_event <= command_fire ? 1'b0
                    : dequant_saturation_now;
                saturation_round_event <= command_fire ? 1'b0
                    : round_saturation_now;
                dsp_issue_valid <= issue_valid;
                dsp_issue_pass1 <= issue_pass1;
                dsp_issue_tag <= issue_tag;
                for (value_index = 0; value_index < 6;
                     value_index = value_index + 1) begin
                    dsp_operand_a[value_index] <= operand_a[value_index];
                    dsp_operand_b[value_index] <= operand_b[value_index];
                end
                mul_valid <= dsp_issue_valid;
                mul_pass1 <= dsp_issue_pass1;
                mul_tag <= dsp_issue_tag;
                sum_valid <= mul_valid;
                sum_pass1 <= mul_pass1;
                sum_tag <= mul_tag;
                if (mul_valid) begin
                    sum_register0 <= next_sum0;
                    sum_register1 <= next_sum1;
                    sum_register2 <= next_sum2;
                end
                magnitude_valid <= sum_valid;
                magnitude_pass1 <= sum_pass1;
                magnitude_tag <= sum_tag;
                if (sum_valid) begin
                    magnitude_negative0 <= sum_register0 < 0;
                    magnitude_negative1 <= sum_register1 < 0;
                    magnitude_negative2 <= sum_register2 < 0;
                    magnitude_register0 <=
                        sum_register0 < 0 ? -sum_register0 : sum_register0;
                    magnitude_register1 <=
                        sum_register1 < 0 ? -sum_register1 : sum_register1;
                    magnitude_register2 <=
                        sum_register2 < 0 ? -sum_register2 : sum_register2;
                end
                rounded_valid <= magnitude_valid;
                rounded_pass1 <= magnitude_pass1;
                rounded_tag <= magnitude_tag;
                if (magnitude_valid) begin
                    rounded_register0 <= rounded_sum0;
                    rounded_register1 <= rounded_sum1;
                    rounded_register2 <= rounded_sum2;
                    rounded_negative0 <= magnitude_negative0;
                    rounded_negative1 <= magnitude_negative1;
                    rounded_negative2 <= magnitude_negative2;
                end

                pixel_valid <= rounded_valid && !rounded_pass1
                            && ((state == S_PASS2)
                                || (state == S_PASS2_DRAIN));
                if (rounded_valid && !rounded_pass1) begin
                    pixel_index <= rounded_tag;
                    pixel_residual <= clip16_signmag(rounded_register0, rounded_negative0);
                    pixel_last <= (rounded_tag == 6'd63);
                    pixel_ctu_index <= active_ctu_index;
                    pixel_block_index <= active_block_index;
                    pixel_plane <= active_plane;
                    pixel_mode <= active_mode;
                end

                if (rounded_valid && rounded_pass1) begin
                    intermediate0[rounded_tag[2:0]] <= clip18_signmag(rounded_register0, rounded_negative0);
                    intermediate1[rounded_tag[2:0]] <= clip18_signmag(rounded_register1, rounded_negative1);
                    intermediate2[rounded_tag[2:0]] <= clip18_signmag(rounded_register2, rounded_negative2);
                end

                case (state)
                    S_DEQUANT: begin
                        state <= S_DEQUANT_DRAIN;
                    end
                    S_DEQUANT_DRAIN: begin
                        if (mul_valid) begin
                            for (value_index = 0; value_index < 6;
                                 value_index = value_index + 1) begin
                                dequantized[value_index] <= clip16(
                                    {{2{product[value_index][31]}},
                                     product[value_index]}
                                );
                            end
                            state <= S_PASS1;
                            issue_index <= 7'd0;
                            mul_valid <= 1'b0;
                            sum_valid <= 1'b0;
                        end
                    end
                    S_PASS1: begin
                        if (issue_valid) begin
                            if (issue_index == 7'd7)
                                state <= S_PASS1_DRAIN;
                            else
                                issue_index <= issue_index + 1'b1;
                        end
                    end
                    S_PASS1_DRAIN: begin
                        if (rounded_valid && rounded_pass1
                            && (rounded_tag == 6'd7)) begin
                            state <= S_PASS2;
                            issue_index <= 7'd0;
                            mul_valid <= 1'b0;
                            sum_valid <= 1'b0;
                        end
                    end
                    S_PASS2: begin
                        if (issue_valid) begin
                            if (issue_index == 7'd63)
                                state <= S_PASS2_DRAIN;
                            else
                                issue_index <= issue_index + 1'b1;
                        end
                    end
                    default: begin end
                endcase
            end

            if (output_fire && pixel_last) begin
                pixel_valid <= 1'b0;
                state <= S_IDLE;
                done <= 1'b1;
                mul_valid <= 1'b0;
                sum_valid <= 1'b0;
                magnitude_valid <= 1'b0;
                rounded_valid <= 1'b0;
            end
        end
    end
endmodule
