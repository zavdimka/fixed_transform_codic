module receiver_full_idct8_32 (
    input  logic         clk,
    input  logic         rst_n,

    input  logic         command_valid,
    output logic         command_ready,
    input  logic [6:0]   command_ctu_index,
    input  logic [2:0]   command_block_index,
    input  logic [1:0]   command_plane,
    input  logic [1:0]   command_mode,
    input  logic [7:0]   command_quality,
    // Physical row-major order, signed 12-bit quantized coefficients.
    input  logic [767:0] command_coefficients,

    output logic         pixel_valid,
    input  logic         pixel_ready,
    output logic [5:0]   pixel_index,
    output logic signed [15:0] pixel_residual,
    output logic signed [15:0] pixel_reference_residual,
    output logic         pixel_last,
    output logic [6:0]   pixel_ctu_index,
    output logic [2:0]   pixel_block_index,
    output logic [1:0]   pixel_plane,
    output logic [1:0]   pixel_mode,
    output logic         done,
    output logic         busy,
    output logic         saturated
);
    localparam logic [2:0] S_IDLE        = 3'd0;
    localparam logic [2:0] S_DEQUANT     = 3'd1;
    localparam logic [2:0] S_DEQ_DRAIN   = 3'd2;
    localparam logic [2:0] S_PASS1       = 3'd3;
    localparam logic [2:0] S_PASS1_DRAIN = 3'd4;
    localparam logic [2:0] S_PASS2       = 3'd5;
    localparam logic [2:0] S_PASS2_DRAIN = 3'd6;

    logic [2:0] state;
    logic [5:0] issue_index;
    logic [6:0] active_ctu_index;
    logic [2:0] active_block_index;
    logic [1:0] active_plane, active_mode;
    logic [7:0] active_quality;

    // Packed register banks are intentional: the transform reads up to 32
    // values per clock, which cannot map to a dual-port EBR.  Keeping these
    // packed also avoids incorrect multi-port RAM inference in Efinity.
    logic [767:0] quantized;
    logic [1023:0] dequantized;
    logic [1151:0] intermediate;
    logic [143:0] pass2_row;
    // Only the right edge enters the predictor for the following CTU.  The
    // first three vertical frequencies cover all six luma (three chroma)
    // base coefficients, so 8x3 values are sufficient for a drift-free
    // base-layer reference.
    logic [431:0] base_intermediate;

    logic issue_valid, issue_pass1, issue_pass2;
    logic [5:0] issue_tag;
    logic signed [17:0] operand_a [0:31];
    logic signed [13:0] operand_b [0:31];
    logic signed [31:0] product [0:31];

    logic product_valid, product_pass1, product_pass2;
    logic [5:0] product_tag;
    logic sum1_valid, sum1_pass1, sum1_pass2;
    logic [5:0] sum1_tag;
    logic signed [32:0] sum1 [0:15];
    logic sum2_valid, sum2_pass1, sum2_pass2;
    logic [5:0] sum2_tag;
    logic signed [33:0] sum2 [0:7];
    logic sum3_valid, sum3_pass1, sum3_pass2;
    logic [5:0] sum3_tag;
    logic signed [34:0] sum3 [0:3];

    logic dequant_valid, dequant_half;
    logic base_product_valid;
    logic [1:0] base_product_frequency;
    logic base_sum_valid;
    logic [1:0] base_sum_frequency;
    logic signed [33:0] base_sum [0:7];
    wire pipeline_advance = !pixel_valid || pixel_ready;
    wire command_fire = command_valid && command_ready;
    wire output_fire = pixel_valid && pixel_ready;

    assign command_ready = (state == S_IDLE);
    assign busy = (state != S_IDLE);

    function automatic logic signed [13:0] basis_value(
        input logic [2:0] frequency,
        input logic [2:0] position
    );
        begin
            case (frequency)
                3'd0: basis_value = 14'sd5793;
                3'd1: case (position)
                    0: basis_value = 14'sd8035; 1: basis_value = 14'sd6811;
                    2: basis_value = 14'sd4551; 3: basis_value = 14'sd1598;
                    4: basis_value = -14'sd1598; 5: basis_value = -14'sd4551;
                    6: basis_value = -14'sd6811; default: basis_value = -14'sd8035;
                endcase
                3'd2: case (position)
                    0: basis_value = 14'sd7568; 1: basis_value = 14'sd3135;
                    2: basis_value = -14'sd3135; 3: basis_value = -14'sd7568;
                    4: basis_value = -14'sd7568; 5: basis_value = -14'sd3135;
                    6: basis_value = 14'sd3135; default: basis_value = 14'sd7568;
                endcase
                3'd3: case (position)
                    0: basis_value = 14'sd6811; 1: basis_value = -14'sd1598;
                    2: basis_value = -14'sd8035; 3: basis_value = -14'sd4551;
                    4: basis_value = 14'sd4551; 5: basis_value = 14'sd8035;
                    6: basis_value = 14'sd1598; default: basis_value = -14'sd6811;
                endcase
                3'd4: case (position)
                    0, 3, 4, 7: basis_value = 14'sd5793;
                    default: basis_value = -14'sd5793;
                endcase
                3'd5: case (position)
                    0: basis_value = 14'sd4551; 1: basis_value = -14'sd8035;
                    2: basis_value = 14'sd1598; 3: basis_value = 14'sd6811;
                    4: basis_value = -14'sd6811; 5: basis_value = -14'sd1598;
                    6: basis_value = 14'sd8035; default: basis_value = -14'sd4551;
                endcase
                3'd6: case (position)
                    0: basis_value = 14'sd3135; 1: basis_value = -14'sd7568;
                    2: basis_value = 14'sd7568; 3: basis_value = -14'sd3135;
                    4: basis_value = -14'sd3135; 5: basis_value = 14'sd7568;
                    6: basis_value = -14'sd7568; default: basis_value = 14'sd3135;
                endcase
                default: case (position)
                    0: basis_value = 14'sd1598; 1: basis_value = -14'sd4551;
                    2: basis_value = 14'sd6811; 3: basis_value = -14'sd8035;
                    4: basis_value = 14'sd8035; 5: basis_value = -14'sd6811;
                    6: basis_value = 14'sd4551; default: basis_value = -14'sd1598;
                endcase
            endcase
        end
    endfunction

    function automatic logic [7:0] quant_divisor(
        input logic quality24,
        input logic chroma,
        input logic [5:0] coefficient_index
    );
        begin
            if (quality24 && chroma) begin
                case (coefficient_index)
                    0: quant_divisor=33; 1: quant_divisor=35; 2: quant_divisor=50; 3: quant_divisor=98; 4,5,6,7: quant_divisor=206;
                    8: quant_divisor=35; 9: quant_divisor=44; 10: quant_divisor=54; 11: quant_divisor=137; 12,13,14,15: quant_divisor=206;
                    16: quant_divisor=50; 17: quant_divisor=54; 18: quant_divisor=116; 19,20,21,22,23: quant_divisor=206;
                    24: quant_divisor=98; 25: quant_divisor=137; default: quant_divisor=206;
                endcase
            end else if (quality24) begin
                case (coefficient_index)
                    0:quant_divisor=31;1:quant_divisor=21;2:quant_divisor=19;3:quant_divisor=33;4:quant_divisor=50;5:quant_divisor=83;6:quant_divisor=106;7:quant_divisor=127;
                    8:quant_divisor=23;9:quant_divisor=23;10:quant_divisor=29;11:quant_divisor=40;12:quant_divisor=54;13:quant_divisor=121;14:quant_divisor=125;15:quant_divisor=114;
                    16:quant_divisor=27;17:quant_divisor=27;18:quant_divisor=33;19:quant_divisor=50;20:quant_divisor=83;21:quant_divisor=119;22:quant_divisor=144;23:quant_divisor=116;
                    24:quant_divisor=29;25:quant_divisor=35;26:quant_divisor=46;27:quant_divisor=60;28:quant_divisor=106;29:quant_divisor=181;30:quant_divisor=166;31:quant_divisor=129;
                    32:quant_divisor=37;33:quant_divisor=46;34:quant_divisor=77;35:quant_divisor=116;36:quant_divisor=141;37:quant_divisor=227;38:quant_divisor=214;39:quant_divisor=160;
                    40:quant_divisor=50;41:quant_divisor=73;42:quant_divisor=114;43:quant_divisor=133;44:quant_divisor=168;45:quant_divisor=216;46:quant_divisor=235;47:quant_divisor=191;
                    48:quant_divisor=102;49:quant_divisor=133;50:quant_divisor=162;51:quant_divisor=181;52:quant_divisor=214;53:quant_divisor=252;54:quant_divisor=250;55:quant_divisor=210;
                    56:quant_divisor=150;57:quant_divisor=191;58:quant_divisor=198;59:quant_divisor=204;60:quant_divisor=233;61:quant_divisor=208;62:quant_divisor=214;default:quant_divisor=206;
                endcase
            end else if (chroma) begin
                case (coefficient_index)
                    0: quant_divisor=39; 1: quant_divisor=41; 2: quant_divisor=60; 3: quant_divisor=118; 4,5,6,7: quant_divisor=248;
                    8: quant_divisor=41; 9: quant_divisor=53; 10: quant_divisor=65; 11: quant_divisor=165; 12,13,14,15: quant_divisor=248;
                    16: quant_divisor=60; 17: quant_divisor=65; 18: quant_divisor=140; 19,20,21,22,23: quant_divisor=248;
                    24: quant_divisor=118; 25: quant_divisor=165; default: quant_divisor=248;
                endcase
            end else begin
                case (coefficient_index)
                    0:quant_divisor=36;1:quant_divisor=25;2:quant_divisor=23;3:quant_divisor=40;4:quant_divisor=60;5:quant_divisor=100;6:quant_divisor=128;7:quant_divisor=153;
                    8:quant_divisor=27;9:quant_divisor=27;10:quant_divisor=35;11:quant_divisor=48;12:quant_divisor=65;13:quant_divisor=145;14:quant_divisor=150;15:quant_divisor=138;
                    16:quant_divisor=32;17:quant_divisor=33;18:quant_divisor=40;19:quant_divisor=60;20:quant_divisor=100;21:quant_divisor=143;22:quant_divisor=173;23:quant_divisor=140;
                    24:quant_divisor=35;25:quant_divisor=43;26:quant_divisor=55;27:quant_divisor=73;28:quant_divisor=128;29:quant_divisor=218;30:quant_divisor=200;31:quant_divisor=155;
                    32:quant_divisor=45;33:quant_divisor=55;34:quant_divisor=93;35:quant_divisor=140;36:quant_divisor=170;37,38:quant_divisor=255;39:quant_divisor=193;
                    40:quant_divisor=60;41:quant_divisor=88;42:quant_divisor=138;43:quant_divisor=160;44:quant_divisor=203;45,46:quant_divisor=255;47:quant_divisor=230;
                    48:quant_divisor=123;49:quant_divisor=160;50:quant_divisor=195;51:quant_divisor=218;52,53,54:quant_divisor=255;55:quant_divisor=253;
                    56:quant_divisor=180;57:quant_divisor=230;58:quant_divisor=238;59:quant_divisor=245;60:quant_divisor=255;61:quant_divisor=250;62:quant_divisor=255;default:quant_divisor=248;
                endcase
            end
        end
    endfunction

    function automatic logic signed [34:0] round_q14(input logic signed [34:0] value);
        logic signed [34:0] magnitude;
        begin
            magnitude = value < 0 ? -value : value;
            magnitude = (magnitude + 35'sd8192) >>> 14;
            round_q14 = value < 0 ? -magnitude : magnitude;
        end
    endfunction

    function automatic logic signed [15:0] clip16(input logic signed [34:0] value);
        if (value > 35'sd32767) clip16 = 16'sd32767;
        else if (value < -35'sd32768) clip16 = -16'sd32768;
        else clip16 = value[15:0];
    endfunction

    function automatic logic signed [17:0] clip18(input logic signed [34:0] value);
        if (value > 35'sd131071) clip18 = 18'sd131071;
        else if (value < -35'sd131072) clip18 = -18'sd131072;
        else clip18 = value[17:0];
    endfunction

    function automatic logic is_base_coefficient(
        input logic [5:0] address,
        input logic chroma
    );
        begin
            if (chroma)
                is_base_coefficient = (address == 0)
                                    || (address == 1)
                                    || (address == 8);
            else
                is_base_coefficient = (address == 0)
                                    || (address == 1)
                                    || (address == 8)
                                    || (address == 16)
                                    || (address == 9)
                                    || (address == 2);
        end
    endfunction

    integer lane, value_index;
    logic [5:0] coefficient_address;
    logic [2:0] pass1_v, pass1_x, pass2_x, pass2_y;
    always_comb begin
        issue_valid = 1'b0;
        issue_pass1 = 1'b0;
        issue_pass2 = 1'b0;
        issue_tag = issue_index;
        coefficient_address = 6'd0;
        pass1_v = issue_index[3:1];
        pass1_x = {issue_index[0], 2'b00};
        pass2_x = issue_index[5:3];
        pass2_y = issue_index[2:0];
        for (lane = 0; lane < 32; lane = lane + 1) begin
            operand_a[lane] = 18'sd0;
            operand_b[lane] = 14'sd0;
        end
        if (state == S_DEQUANT) begin
            issue_valid = 1'b1;
            for (lane = 0; lane < 32; lane = lane + 1) begin
                coefficient_address = {issue_index[0], 5'd0} + 6'(lane);
                operand_a[lane] = {{6{quantized[
                    coefficient_address * 12 + 11]}},
                    quantized[coefficient_address * 12 +: 12]};
                operand_b[lane] = $signed({6'd0, quant_divisor(active_quality == 8'd24, active_plane != 0, coefficient_address)});
            end
        end else if (state == S_PASS1) begin
            issue_valid = 1'b1;
            issue_pass1 = 1'b1;
            for (lane = 0; lane < 32; lane = lane + 1) begin
                operand_a[lane] = {{2{dequantized[
                    {lane[2:0], pass1_v} * 16 + 15]}},
                    dequantized[{lane[2:0], pass1_v} * 16 +: 16]};
                operand_b[lane] = basis_value(lane[2:0], pass1_x + 3'(lane >> 3));
            end
        end else if (state == S_PASS2) begin
            issue_valid = 1'b1;
            issue_pass2 = 1'b1;
            for (lane = 0; lane < 8; lane = lane + 1) begin
                operand_a[lane] = pass2_row[lane * 18 +: 18];
                operand_b[lane] = basis_value(lane[2:0], pass2_y);
            end
            // The full pass uses only lanes 0..7.  During its first three
            // cycles lanes 8..31 form all base-only horizontal intermediates.
            if (issue_index < 3) begin
                for (lane = 0; lane < 24; lane = lane + 1) begin
                    coefficient_address = 6'(lane % 3) * 6'd8
                                        + issue_index;
                    operand_a[8 + lane] = is_base_coefficient(
                        coefficient_address, active_plane != 0
                    ) ? {{2{dequantized[
                            coefficient_address * 16 + 15]}},
                         dequantized[
                            coefficient_address * 16 +: 16]} : 18'sd0;
                    operand_b[8 + lane] = basis_value(
                        3'(lane % 3), 3'(lane / 3)
                    );
                end
            end else if (pass2_y == 3'd7) begin
                // On a right-edge output, group 1 of the existing adder tree
                // calculates the base-only reference sample in parallel.
                for (lane = 0; lane < 3; lane = lane + 1) begin
                    operand_a[8 + lane] = base_intermediate[
                        (pass2_x * 3 + lane) * 18 +: 18
                    ];
                    operand_b[8 + lane] = basis_value(lane[2:0], 3'd7);
                end
            end
        end
    end

    genvar multiplier_lane;
    generate for (multiplier_lane = 0; multiplier_lane < 32; multiplier_lane = multiplier_lane + 1) begin : multipliers
        always_ff @(posedge clk) begin
            if (pipeline_advance && issue_valid)
                product[multiplier_lane] <= operand_a[multiplier_lane] * operand_b[multiplier_lane];
        end
    end endgenerate

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE;
            issue_index <= 6'd0;
            active_ctu_index <= 7'd0;
            active_block_index <= 3'd0;
            active_plane <= 2'd0;
            active_mode <= 2'd0;
            active_quality <= 8'd0;
            product_valid <= 1'b0; sum1_valid <= 1'b0;
            sum2_valid <= 1'b0; sum3_valid <= 1'b0;
            product_pass1 <= 1'b0; product_pass2 <= 1'b0;
            sum1_pass1 <= 1'b0; sum1_pass2 <= 1'b0;
            sum2_pass1 <= 1'b0; sum2_pass2 <= 1'b0;
            sum3_pass1 <= 1'b0; sum3_pass2 <= 1'b0;
            product_tag <= 6'd0; sum1_tag <= 6'd0;
            sum2_tag <= 6'd0; sum3_tag <= 6'd0;
            dequant_valid <= 1'b0; dequant_half <= 1'b0;
            base_product_valid <= 1'b0;
            base_product_frequency <= 2'd0;
            base_sum_valid <= 1'b0;
            base_sum_frequency <= 2'd0;
            pixel_valid <= 1'b0; pixel_index <= 6'd0;
            pixel_residual <= 16'sd0; pixel_last <= 1'b0;
            pixel_reference_residual <= 16'sd0;
            pixel_ctu_index <= 7'd0; pixel_block_index <= 3'd0;
            pixel_plane <= 2'd0; pixel_mode <= 2'd0;
            done <= 1'b0; saturated <= 1'b0;
            // Datapath banks deliberately have no reset.  Their contents are
            // hidden by the valid/state pipeline and every entry is written
            // before its first read.  Avoiding a reset mux on thousands of
            // data bits substantially improves LE packing and reset routing.
        end else begin
            done <= 1'b0;
            if (command_fire) begin
                active_ctu_index <= command_ctu_index;
                active_block_index <= command_block_index;
                active_plane <= command_plane;
                active_mode <= command_mode;
                active_quality <= command_quality;
                quantized <= command_coefficients;
                state <= S_DEQUANT;
                issue_index <= 6'd0;
                product_valid <= 1'b0; sum1_valid <= 1'b0;
                sum2_valid <= 1'b0; sum3_valid <= 1'b0;
                dequant_valid <= 1'b0; pixel_valid <= 1'b0;
                base_product_valid <= 1'b0;
                base_sum_valid <= 1'b0;
                saturated <= 1'b0;
            end

            if (pipeline_advance) begin
                product_valid <= issue_valid && (state != S_DEQUANT);
                product_pass1 <= issue_pass1;
                product_pass2 <= issue_pass2;
                product_tag <= issue_tag;
                sum1_valid <= product_valid;
                sum1_pass1 <= product_pass1; sum1_pass2 <= product_pass2;
                sum1_tag <= product_tag;
                sum2_valid <= sum1_valid;
                sum2_pass1 <= sum1_pass1; sum2_pass2 <= sum1_pass2;
                sum2_tag <= sum1_tag;
                sum3_valid <= sum2_valid;
                sum3_pass1 <= sum2_pass1; sum3_pass2 <= sum2_pass2;
                sum3_tag <= sum2_tag;
                for (value_index = 0; value_index < 16; value_index = value_index + 1)
                    sum1[value_index] <= $signed(product[value_index * 2]) + $signed(product[value_index * 2 + 1]);
                for (value_index = 0; value_index < 8; value_index = value_index + 1)
                    sum2[value_index] <= $signed(sum1[value_index * 2]) + $signed(sum1[value_index * 2 + 1]);
                for (value_index = 0; value_index < 4; value_index = value_index + 1)
                    sum3[value_index] <= $signed(sum2[value_index * 2]) + $signed(sum2[value_index * 2 + 1]);

                dequant_valid <= (state == S_DEQUANT) && issue_valid;
                dequant_half <= issue_index[0];
                base_product_valid <= (state == S_PASS2)
                                   && (issue_index < 3);
                base_product_frequency <= issue_index[1:0];
                base_sum_valid <= base_product_valid;
                base_sum_frequency <= base_product_frequency;
                if (dequant_valid) begin
                    for (value_index = 0; value_index < 32; value_index = value_index + 1) begin
                        dequantized[
                            {dequant_half, value_index[4:0]} * 16 +: 16
                        ] <= clip16({{3{product[value_index][31]}},
                                     product[value_index]});
                        if ((product[value_index] > 32'sd32767) || (product[value_index] < -32'sd32768)) saturated <= 1'b1;
                    end
                end

                if (sum3_valid && sum3_pass1) begin
                    for (value_index = 0; value_index < 4; value_index = value_index + 1) begin
                        intermediate[
                            {sum3_tag[0], value_index[1:0],
                             sum3_tag[3:1]} * 18 +: 18
                        ] <= clip18(round_q14(sum3[value_index]));
                        if ((round_q14(sum3[value_index]) > 35'sd131071) || (round_q14(sum3[value_index]) < -35'sd131072)) saturated <= 1'b1;
                    end
                end

                if (base_product_valid) begin
                    for (value_index = 0; value_index < 8;
                         value_index = value_index + 1)
                        base_sum[value_index] <=
                            {{2{product[8 + value_index * 3][31]}},
                              product[8 + value_index * 3]}
                          + {{2{product[9 + value_index * 3][31]}},
                              product[9 + value_index * 3]}
                          + {{2{product[10 + value_index * 3][31]}},
                              product[10 + value_index * 3]};
                end

                if (base_sum_valid) begin
                    for (value_index = 0; value_index < 8;
                         value_index = value_index + 1)
                        base_intermediate[
                            (5'(value_index * 3)
                             + {3'd0, base_sum_frequency}) * 18 +: 18
                        ] <= clip18(round_q14(
                            {{1{base_sum[value_index][33]}},
                              base_sum[value_index]}
                        ));
                end

                pixel_valid <= sum3_valid && sum3_pass2;
                if (sum3_valid && sum3_pass2) begin
                    pixel_index <= sum3_tag;
                    pixel_residual <= clip16(round_q14(sum3[0]));
                    pixel_reference_residual <=
                        (sum3_tag[2:0] == 3'd7)
                        ? clip16(round_q14(sum3[1]))
                        : clip16(round_q14(sum3[0]));
                    pixel_last <= (sum3_tag == 6'd63);
                    pixel_ctu_index <= active_ctu_index;
                    pixel_block_index <= active_block_index;
                    pixel_plane <= active_plane;
                    pixel_mode <= active_mode;
                    if ((round_q14(sum3[0]) > 35'sd32767) || (round_q14(sum3[0]) < -35'sd32768)) saturated <= 1'b1;
                end

                case (state)
                    S_DEQUANT: begin
                        if (issue_index == 6'd1) state <= S_DEQ_DRAIN;
                        else issue_index <= issue_index + 1'b1;
                    end
                    S_DEQ_DRAIN: if (dequant_valid && dequant_half) begin
                        state <= S_PASS1; issue_index <= 6'd0;
                    end
                    S_PASS1: begin
                        if (issue_index == 6'd15) state <= S_PASS1_DRAIN;
                        else issue_index <= issue_index + 1'b1;
                    end
                    S_PASS1_DRAIN: if (sum3_valid && sum3_pass1 && (sum3_tag == 6'd15)) begin
                        state <= S_PASS2;
                        issue_index <= 6'd0;
                        pass2_row <= intermediate[0 +: 144];
                    end
                    S_PASS2: begin
                        if ((issue_index[2:0] == 3'd7)
                            && (issue_index != 6'd63))
                            pass2_row <= intermediate[
                                (32'(pass2_x) + 32'd1) * 144 +: 144
                            ];
                        if (issue_index == 6'd63) state <= S_PASS2_DRAIN;
                        else issue_index <= issue_index + 1'b1;
                    end
                    default: begin end
                endcase
            end

            if (output_fire && pixel_last) begin
                pixel_valid <= 1'b0;
                state <= S_IDLE;
                done <= 1'b1;
                product_valid <= 1'b0; sum1_valid <= 1'b0;
                sum2_valid <= 1'b0; sum3_valid <= 1'b0;
            end
        end
    end
endmodule
