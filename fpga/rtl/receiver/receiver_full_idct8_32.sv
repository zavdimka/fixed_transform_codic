module receiver_full_idct8_32 #(
    // Select the narrow local coefficient loader instead of the legacy
    // global 768-bit command bus.
    parameter bit STREAM_LOAD = 1'b0
) (
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

    input  logic         load_start_valid,
    output logic         load_start_ready,
    input  logic [6:0]   load_ctu_index,
    input  logic [2:0]   load_block_index,
    input  logic [1:0]   load_plane,
    input  logic [1:0]   load_mode,
    input  logic [7:0]   load_quality,
    input  logic         load_coeff_valid,
    output logic         load_coeff_ready,
    input  logic [5:0]   load_coeff_address,
    input  logic signed [11:0] load_coeff_data,
    input  logic         load_base_valid,
    output logic         load_base_ready,
    input  logic [71:0]  load_base_coefficients,
    input  logic         load_base_plane,
    input  logic         load_commit_valid,
    output logic         load_commit_ready,
    input  logic         load_abort,

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
    localparam logic [2:0] F_IDLE        = 3'd0;
    localparam logic [2:0] F_DEQUANT     = 3'd1;
    localparam logic [2:0] F_DEQ_DRAIN   = 3'd2;
    localparam logic [2:0] F_PASS1       = 3'd3;
    localparam logic [2:0] F_PASS1_DRAIN = 3'd4;
    localparam logic [2:0] F_BASE        = 3'd5;
    localparam logic [2:0] F_BASE_DRAIN  = 3'd6;

    // Two banks decouple the 38-cycle preparation stage from the 64-cycle
    // output stage, while both stages still share the same 32 multipliers.
    logic [1:0] bank_occupied, bank_ready;
    logic [767:0] quantized_front;
    logic [63:0] quantized_valid;
    logic coefficient_write_pending;
    logic [5:0] coefficient_write_address;
    logic signed [11:0] coefficient_write_data;
    logic [7:0] coefficient_bank_write_enable;
    logic [2:0] coefficient_bank_write_index;
    logic signed [11:0] coefficient_bank_write_data;
    logic [1023:0] dequantized_front;
    logic [1151:0] intermediate_bank [0:1];
    logic [431:0] base_intermediate_bank [0:1];
    logic [6:0] bank_ctu_index [0:1];
    logic [2:0] bank_block_index [0:1];
    logic [1:0] bank_plane [0:1], bank_mode [0:1];
    logic [7:0] bank_quality [0:1];
    logic [1:0] bank_saturated;

    logic front_active, front_bank;
    logic front_is_chroma, front_quality24;
    logic [2:0] front_state;
    logic [5:0] front_issue;
    // One replicated selector per pass-1 DSP lane keeps fanout and routing local.
    (* syn_keep = 1, syn_preserve = 1 *)
    logic [4:0] front_issue_pass1 [0:15];
    logic back_active, back_bank, back_all_issued;
    logic [5:0] back_issue;
    logic [53:0] base_edge_row;
    logic [47:0] base_dequant_row;

    logic signed [17:0] operand_a [0:31];
    logic signed [13:0] operand_b [0:31];
    logic signed [17:0] operand_a_pipe [0:31];
    logic signed [13:0] operand_b_pipe [0:31];
    logic signed [31:0] product [0:31];

    logic issue_back_valid, issue_front_dequant;
    logic issue_front_pass1, issue_front_base;
    logic [5:0] issue_back_tag, issue_front_tag;
    logic issue_front_bank, issue_back_bank;
    logic op_back_valid, op_front_dequant, op_front_pass1, op_front_base;
    logic [5:0] op_back_tag, op_front_tag;
    logic op_front_bank, op_back_bank;
    logic prod_back_valid, prod_front_dequant, prod_front_pass1, prod_front_base;
    logic [5:0] prod_back_tag, prod_front_tag;
    logic prod_front_bank, prod_back_bank;

    logic back_s1_valid, back_s2_valid, back_s3_valid;
    logic [5:0] back_s1_tag, back_s2_tag, back_s3_tag;
    logic back_s1_bank, back_s2_bank, back_s3_bank;
    logic signed [32:0] back_sum1 [0:3];
    logic signed [33:0] back_sum2 [0:1];
    logic signed [34:0] back_sum3;
    logic signed [32:0] back_base_pair, back_base_tail;
    logic signed [33:0] back_base_sum2;
    logic signed [34:0] back_base_sum3;

    logic pass1_s1_valid, pass1_s2_valid, pass1_s3_valid;
    logic [5:0] pass1_s1_tag, pass1_s2_tag, pass1_s3_tag;
    logic pass1_s1_bank, pass1_s2_bank, pass1_s3_bank;
    logic pass1_write_valid;
    logic [5:0] pass1_write_tag;
    logic pass1_write_bank;
    logic signed [32:0] pass1_sum1 [0:7];
    logic signed [33:0] pass1_sum2 [0:3];
    logic signed [34:0] pass1_sum3 [0:1];
    logic signed [34:0] pass1_rounded [0:1];

    logic base_sum_valid;
    logic [1:0] base_sum_frequency;
    logic base_sum_bank;
    logic signed [33:0] base_sum [0:7];
    logic base_write_valid;
    logic [1:0] base_write_frequency;
    logic base_write_bank;
    logic signed [34:0] base_rounded [0:7];
    logic [15:0] dequant_product_low [0:23];
    logic [23:0] dequant_clip_high, dequant_clip_low;
    logic dequant_write_valid, dequant_write_bank;
    logic [1:0] dequant_write_tag;
    logic [23:0] dequant_overflow_bits;
    logic [1:0] pass1_overflow_bits;
    logic back_overflow_bit;
    logic dequant_overflow_valid, dequant_overflow_bank;
    logic pass1_overflow_valid, pass1_overflow_bank;
    logic back_overflow_valid, back_overflow_bank;

    logic load_active, stream_pending;
    logic [6:0] stream_ctu_index;
    logic [2:0] stream_block_index;
    logic [1:0] stream_plane, stream_mode;
    logic [7:0] stream_quality;

    wire pipeline_advance = !pixel_valid || pixel_ready;
    wire transform_slot_ready = !front_active
                              && !(bank_occupied[0] && bank_occupied[1]);
    wire legacy_command_fire = !STREAM_LOAD && command_valid
                             && transform_slot_ready;
    wire stream_command_fire = STREAM_LOAD && stream_pending
                             && transform_slot_ready;
    wire command_fire = legacy_command_fire || stream_command_fire;
    wire load_start_fire = load_start_valid && load_start_ready;
    wire load_coeff_fire = load_coeff_valid && load_coeff_ready;
    wire load_base_fire = load_base_valid && load_base_ready;
    wire load_commit_fire = load_commit_valid && load_commit_ready;
    wire output_fire = pixel_valid && pixel_ready;
    wire free_bank = bank_occupied[0];
    wire back_right_edge = back_active && !back_all_issued
                         && (back_issue[2:0] == 3'd7);
    wire front_can_issue = front_active;


    assign command_ready = !STREAM_LOAD && transform_slot_ready;
    // quantized_front is read only while F_DEQUANT issues its three groups.
    // Afterwards it is reused as the load bank for the following block.
    assign load_coeff_ready = STREAM_LOAD && load_active;
    assign load_base_ready = STREAM_LOAD && load_active;
    assign busy = |bank_occupied;
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
        begin
            // Symmetric round-to-nearest without the former absolute-value
            // and sign-restore negators.  For a negative two's-complement
            // value, adding 2^13-1 before the arithmetic shift is exactly
            // equivalent to -(abs(value)+2^13)>>14.
            round_q14 = (value + (value[34] ? 35'sd8191 : 35'sd8192)) >>> 14;
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

    integer lane, value_index, coefficient_address;
    always_comb begin
        issue_back_valid = back_active && !back_all_issued;
        issue_back_tag = back_issue;
        issue_back_bank = back_bank;
        issue_front_dequant = 1'b0;
        issue_front_pass1 = 1'b0;
        issue_front_base = 1'b0;
        issue_front_tag = front_issue;
        issue_front_bank = front_bank;
        coefficient_address = 0;

        for (lane = 0; lane < 32; lane = lane + 1) begin
            operand_a[lane] = 18'sd0;
            operand_b[lane] = 14'sd0;
        end

        // These inputs may toggle while the backend is idle; op_back_valid
        // suppresses their products. Removing the idle-to-zero mux keeps the
        // backend control flags completely off the DSP input paths.
        for (lane = 0; lane < 8; lane = lane + 1) begin
            operand_a[lane] = intermediate_bank[back_bank][
                (32'(back_issue[5:3]) * 8 + lane) * 18 +: 18
            ];
            operand_b[lane] = basis_value(lane[2:0], back_issue[2:0]);
        end

        if (front_can_issue) begin
            case (front_state)
                F_DEQUANT: begin
                    issue_front_dequant = !back_right_edge;
                    for (lane = 8; lane < 32; lane = lane + 1) begin
                        coefficient_address = 32'(front_issue[1:0]) * 24
                                            + lane - 8;
                        if (coefficient_address < 64
                            && (!STREAM_LOAD
                                || quantized_valid[coefficient_address])) begin
                            operand_a[lane] = {{6{quantized_front[
                                coefficient_address * 12 + 11]}},
                                quantized_front[
                                coefficient_address * 12 +: 12]};
                            operand_b[lane] = $signed({6'd0, quant_divisor(
                                front_quality24,
                                front_is_chroma,
                                6'(coefficient_address)
                            )});
                        end
                    end
                end
                F_PASS1: begin
                    issue_front_pass1 = 1'b1;
                    for (lane = 0; lane < 16; lane = lane + 1) begin
                        operand_a[16 + lane] = {{2{dequantized_front[
                            (32'(lane[2:0]) * 8
                             + front_issue_pass1[lane][4:2])
                            * 16 + 15]}}, dequantized_front[
                            (32'(lane[2:0]) * 8
                             + front_issue_pass1[lane][4:2])
                            * 16 +: 16]};
                        operand_b[16 + lane] = basis_value(
                            lane[2:0],
                            {front_issue_pass1[lane][1:0], 1'b0}
                            + 3'(lane >> 3)
                        );
                    end
                end
                F_BASE: begin
                    issue_front_base = !back_right_edge;
                    for (lane = 0; lane < 24; lane = lane + 1) begin
                        operand_a[8 + lane] = {{
                            2{base_dequant_row[
                                (lane % 3) * 16 + 15]}},
                            base_dequant_row[
                                (lane % 3) * 16 +: 16]};
                        operand_b[8 + lane] = basis_value(
                            3'(lane % 3), 3'(lane / 3)
                        );
                    end
                end
                default: begin end
            endcase
        end

        // A pass-2 right-edge cycle borrows only DSP lanes 8..10. Override
        // those operands after the front-end mux instead of fanning the
        // backend state into every front operand. The front result-valid bit
        // is suppressed above for the two states that use these lanes.
        if (back_right_edge) begin
            for (lane = 0; lane < 3; lane = lane + 1) begin
                operand_a[8 + lane] = base_edge_row[lane * 18 +: 18];
                operand_b[8 + lane] = basis_value(lane[2:0], 3'd7);
            end
        end
    end

    genvar multiplier_lane;
    generate for (multiplier_lane = 0; multiplier_lane < 32;
                  multiplier_lane = multiplier_lane + 1) begin : multipliers
        always_ff @(posedge clk) begin
            if (pipeline_advance) begin
                operand_a_pipe[multiplier_lane] <= operand_a[multiplier_lane];
                operand_b_pipe[multiplier_lane] <= operand_b[multiplier_lane];
                product[multiplier_lane] <=
                    operand_a_pipe[multiplier_lane]
                  * operand_b_pipe[multiplier_lane];
            end
        end
    end endgenerate

    // This 1024-bit bank is protected by dequant_write_valid and the front
    // state machine. Keeping it outside the reset-controlled process avoids
    // routing reset_60_n into every data FF clock-enable.
    always_ff @(posedge clk) begin
        if (pipeline_advance && dequant_write_valid) begin
            for (value_index = 0; value_index < 24;
                 value_index = value_index + 1) begin
                if ((32'(dequant_write_tag) * 24 + value_index) < 64) begin
                    if (dequant_clip_high[value_index])
                        dequantized_front[
                            (32'(dequant_write_tag) * 24
                             + value_index) * 16 +: 16
                        ] <= 16'sd32767;
                    else if (dequant_clip_low[value_index])
                        dequantized_front[
                            (32'(dequant_write_tag) * 24
                             + value_index) * 16 +: 16
                        ] <= -16'sd32768;
                    else
                        dequantized_front[
                            (32'(dequant_write_tag) * 24
                             + value_index) * 16 +: 16
                        ] <= dequant_product_low[value_index];
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            bank_occupied <= 2'b00;
            bank_ready <= 2'b00;
            bank_saturated <= 2'b00;
            front_active <= 1'b0;
            front_bank <= 1'b0;
            front_state <= F_IDLE;
            front_issue <= 6'd0;
            for (value_index = 0; value_index < 16;
                 value_index = value_index + 1)
                front_issue_pass1[value_index] <= 5'd0;
            back_active <= 1'b0;
            back_bank <= 1'b0;
            back_all_issued <= 1'b0;
            back_issue <= 6'd0;

            op_back_valid <= 1'b0;
            op_front_dequant <= 1'b0;
            op_front_pass1 <= 1'b0;
            op_front_base <= 1'b0;
            prod_back_valid <= 1'b0;
            prod_front_dequant <= 1'b0;
            prod_front_pass1 <= 1'b0;
            prod_front_base <= 1'b0;
            back_s1_valid <= 1'b0;
            back_s2_valid <= 1'b0;
            back_s3_valid <= 1'b0;
            pass1_s1_valid <= 1'b0;
            pass1_s2_valid <= 1'b0;
            pass1_s3_valid <= 1'b0;
            pass1_write_valid <= 1'b0;
            base_sum_valid <= 1'b0;
            base_write_valid <= 1'b0;
            dequant_overflow_valid <= 1'b0;
            pass1_overflow_valid <= 1'b0;
            back_overflow_valid <= 1'b0;

            pixel_valid <= 1'b0;
            pixel_index <= 6'd0;
            pixel_residual <= 16'sd0;
            pixel_reference_residual <= 16'sd0;
            pixel_last <= 1'b0;
            pixel_ctu_index <= 7'd0;
            pixel_block_index <= 3'd0;
            pixel_plane <= 2'd0;
            pixel_mode <= 2'd0;
            done <= 1'b0;
            saturated <= 1'b0;
            quantized_valid <= 64'd0;
            load_active <= 1'b0;
            stream_pending <= 1'b0;
            stream_ctu_index <= 7'd0;
            stream_block_index <= 3'd0;
            stream_plane <= 2'd0;
            stream_mode <= 2'd0;
            stream_quality <= 8'd0;
            load_start_ready <= 1'b0;
            load_commit_ready <= 1'b0;
            coefficient_write_pending <= 1'b0;
            coefficient_write_address <= 6'd0;
            coefficient_write_data <= 12'sd0;
            coefficient_bank_write_enable <= 8'd0;
            coefficient_bank_write_index <= 3'd0;
            coefficient_bank_write_data <= 12'sd0;
            // Wide datapath banks deliberately have no reset. Valid bits and
            // bank ownership hide their contents until every entry is written.
        end else begin
            done <= 1'b0;
            coefficient_write_pending <= 1'b0;
            coefficient_bank_write_enable <= 8'd0;

            if (load_start_fire)
                load_start_ready <= 1'b0;
            else
                load_start_ready <= STREAM_LOAD && !load_active
                    && !stream_pending
                    && (!front_active || (front_state != F_DEQUANT));
            if (load_commit_fire)
                load_commit_ready <= 1'b0;
            else
                load_commit_ready <= STREAM_LOAD && load_active
                    && transform_slot_ready;

            if (STREAM_LOAD && load_abort) begin
                load_active <= 1'b0;
                stream_pending <= 1'b0;
                quantized_valid <= 64'd0;
            end else begin
                if (load_start_fire) begin
                    load_active <= 1'b1;
                    quantized_valid <= 64'd0;

                end
                if (load_coeff_fire) begin
                    coefficient_write_pending <= 1'b1;
                    coefficient_write_address <= load_coeff_address;
                    coefficient_write_data <= load_coeff_data;
                end
                if (coefficient_write_pending) begin
                    coefficient_bank_write_enable <=
                        8'b1 << coefficient_write_address[5:3];
                    coefficient_bank_write_index <=
                        coefficient_write_address[2:0];
                    coefficient_bank_write_data <= coefficient_write_data;
                end
                for (value_index = 0; value_index < 8;
                     value_index = value_index + 1) begin
                    if (coefficient_bank_write_enable[value_index]) begin
                        quantized_front[
                            (value_index * 8 + coefficient_bank_write_index)
                            * 12 +: 12
                        ] <= coefficient_bank_write_data;
                        quantized_valid[
                            value_index * 8 + coefficient_bank_write_index
                        ] <= 1'b1;
                    end
                end
                if (load_base_fire) begin
                    quantized_front[0 * 12 +: 12]
                        <= load_base_coefficients[0 * 12 +: 12];
                    quantized_front[1 * 12 +: 12]
                        <= load_base_coefficients[1 * 12 +: 12];
                    quantized_front[8 * 12 +: 12]
                        <= load_base_coefficients[2 * 12 +: 12];
                    quantized_valid[0] <= 1'b1;
                    quantized_valid[1] <= 1'b1;
                    quantized_valid[8] <= 1'b1;
                    if (!load_base_plane) begin
                        quantized_front[16 * 12 +: 12]
                            <= load_base_coefficients[3 * 12 +: 12];
                        quantized_front[9 * 12 +: 12]
                            <= load_base_coefficients[4 * 12 +: 12];
                        quantized_front[2 * 12 +: 12]
                            <= load_base_coefficients[5 * 12 +: 12];
                        quantized_valid[16] <= 1'b1;
                        quantized_valid[9] <= 1'b1;
                        quantized_valid[2] <= 1'b1;
                    end
                end
                if (load_commit_fire) begin
                    load_active <= 1'b0;
                    stream_pending <= 1'b1;
                    stream_ctu_index <= load_ctu_index;
                    stream_block_index <= load_block_index;
                    stream_plane <= load_plane;
                    stream_mode <= load_mode;
                    stream_quality <= load_quality;
                end
                if (stream_command_fire)
                    stream_pending <= 1'b0;
            end

            if (command_fire) begin
                bank_occupied[free_bank] <= 1'b1;
                bank_ready[free_bank] <= 1'b0;
                bank_saturated[free_bank] <= 1'b0;
                bank_ctu_index[free_bank] <= STREAM_LOAD
                    ? stream_ctu_index : command_ctu_index;
                bank_block_index[free_bank] <= STREAM_LOAD
                    ? stream_block_index : command_block_index;
                bank_plane[free_bank] <= STREAM_LOAD
                    ? stream_plane : command_plane;
                bank_mode[free_bank] <= STREAM_LOAD
                    ? stream_mode : command_mode;
                front_quality24 <= ((STREAM_LOAD
                    ? stream_quality : command_quality) == 8'd24);
                front_is_chroma <= (STREAM_LOAD
                    ? (stream_plane != 0) : (command_plane != 0));
                if (!STREAM_LOAD) begin
                    quantized_front <= command_coefficients;
                    quantized_valid <= 64'hffff_ffff_ffff_ffff;
                end
                front_active <= 1'b1;
                front_bank <= free_bank;
                front_state <= F_DEQUANT;
                front_issue <= 6'd0;
            end

            if (!back_active && (|bank_ready)) begin
                back_active <= 1'b1;
                back_all_issued <= 1'b0;
                back_issue <= 6'd0;
                if (bank_ready[0]) begin
                    back_bank <= 1'b0;
                    bank_ready[0] <= 1'b0;
                    base_edge_row <= base_intermediate_bank[0][0 +: 54];
                    saturated <= bank_saturated[0];
                end else begin
                    back_bank <= 1'b1;
                    bank_ready[1] <= 1'b0;
                    base_edge_row <= base_intermediate_bank[1][0 +: 54];
                    saturated <= bank_saturated[1];
                end
            end

            if (pipeline_advance) begin
                op_back_valid <= issue_back_valid;
                op_back_tag <= issue_back_tag;
                op_back_bank <= issue_back_bank;
                op_front_dequant <= issue_front_dequant;
                op_front_pass1 <= issue_front_pass1;
                op_front_base <= issue_front_base;
                op_front_tag <= issue_front_tag;
                op_front_bank <= issue_front_bank;

                prod_back_valid <= op_back_valid;
                prod_back_tag <= op_back_tag;
                prod_back_bank <= op_back_bank;
                prod_front_dequant <= op_front_dequant;
                prod_front_pass1 <= op_front_pass1;
                prod_front_base <= op_front_base;
                prod_front_tag <= op_front_tag;
                prod_front_bank <= op_front_bank;

                back_s1_valid <= prod_back_valid;
                back_s1_tag <= prod_back_tag;
                back_s1_bank <= prod_back_bank;
                back_s2_valid <= back_s1_valid;
                back_s2_tag <= back_s1_tag;
                back_s2_bank <= back_s1_bank;
                back_s3_valid <= back_s2_valid;
                back_s3_tag <= back_s2_tag;
                back_s3_bank <= back_s2_bank;

                pass1_s1_valid <= prod_front_pass1;
                pass1_s1_tag <= prod_front_tag;
                pass1_s1_bank <= prod_front_bank;
                pass1_s2_valid <= pass1_s1_valid;
                pass1_s2_tag <= pass1_s1_tag;
                pass1_s2_bank <= pass1_s1_bank;
                pass1_s3_valid <= pass1_s2_valid;
                pass1_s3_tag <= pass1_s2_tag;
                pass1_s3_bank <= pass1_s2_bank;

                if (prod_back_valid) begin
                    for (value_index = 0; value_index < 4;
                         value_index = value_index + 1)
                        back_sum1[value_index] <=
                            $signed(product[value_index * 2])
                          + $signed(product[value_index * 2 + 1]);
                    back_base_pair <= $signed(product[8])
                                    + $signed(product[9]);
                    back_base_tail <= {{1{product[10][31]}}, product[10]};
                end
                if (back_s1_valid) begin
                    back_sum2[0] <= $signed(back_sum1[0])
                                  + $signed(back_sum1[1]);
                    back_sum2[1] <= $signed(back_sum1[2])
                                  + $signed(back_sum1[3]);
                    back_base_sum2 <= $signed(back_base_pair)
                                    + $signed(back_base_tail);
                end
                if (back_s2_valid) begin
                    back_sum3 <= $signed(back_sum2[0])
                               + $signed(back_sum2[1]);
                    back_base_sum3 <= {{1{back_base_sum2[33]}},
                                       back_base_sum2};
                end

                if (prod_front_pass1) begin
                    for (value_index = 0; value_index < 8;
                         value_index = value_index + 1)
                        pass1_sum1[value_index] <=
                            $signed(product[16 + value_index * 2])
                          + $signed(product[17 + value_index * 2]);
                end
                if (pass1_s1_valid) begin
                    for (value_index = 0; value_index < 4;
                         value_index = value_index + 1)
                        pass1_sum2[value_index] <=
                            $signed(pass1_sum1[value_index * 2])
                          + $signed(pass1_sum1[value_index * 2 + 1]);
                end
                if (pass1_s2_valid) begin
                    pass1_sum3[0] <= $signed(pass1_sum2[0])
                                   + $signed(pass1_sum2[1]);
                    pass1_sum3[1] <= $signed(pass1_sum2[2])
                                   + $signed(pass1_sum2[3]);
                end

                dequant_write_valid <= prod_front_dequant;
                dequant_write_tag <= prod_front_tag[1:0];
                dequant_write_bank <= prod_front_bank;
                if (prod_front_dequant) begin
                    for (value_index = 0; value_index < 24;
                         value_index = value_index + 1) begin
                        dequant_product_low[value_index] <=
                            product[8 + value_index][15:0];
                        dequant_clip_high[value_index] <=
                            !product[8 + value_index][31]
                          && (|product[8 + value_index][30:15]);
                        dequant_clip_low[value_index] <=
                            product[8 + value_index][31]
                          && !(&product[8 + value_index][30:15]);
                        dequant_overflow_bits[value_index] <=
                            (!product[8 + value_index][31]
                             && (|product[8 + value_index][30:15]))
                          || (product[8 + value_index][31]
                             && !(&product[8 + value_index][30:15]));
                    end
                end

                pass1_write_valid <= pass1_s3_valid;
                pass1_write_tag <= pass1_s3_tag;
                pass1_write_bank <= pass1_s3_bank;
                if (pass1_s3_valid) begin
                    for (value_index = 0; value_index < 2;
                         value_index = value_index + 1)
                        pass1_rounded[value_index] <=
                            round_q14(pass1_sum3[value_index]);
                end
                if (pass1_write_valid) begin
                    for (value_index = 0; value_index < 2;
                         value_index = value_index + 1) begin
                        intermediate_bank[pass1_write_bank][
                            ((32'(pass1_write_tag[1:0]) * 2 + value_index) * 8
                             + 32'(pass1_write_tag[4:2])) * 18 +: 18
                        ] <= clip18(pass1_rounded[value_index]);
                        pass1_overflow_bits[value_index] <=
                            (pass1_rounded[value_index] > 35'sd131071)
                         || (pass1_rounded[value_index] < -35'sd131072);
                    end
                end

                base_sum_valid <= prod_front_base;
                base_sum_frequency <= prod_front_tag[1:0];
                base_sum_bank <= prod_front_bank;
                if (prod_front_base) begin
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
                base_write_valid <= base_sum_valid;
                base_write_frequency <= base_sum_frequency;
                base_write_bank <= base_sum_bank;
                if (base_sum_valid) begin
                    for (value_index = 0; value_index < 8;
                         value_index = value_index + 1)
                        base_rounded[value_index] <= round_q14(
                            {{1{base_sum[value_index][33]}},
                              base_sum[value_index]}
                        );
                end
                if (base_write_valid) begin
                    for (value_index = 0; value_index < 8;
                         value_index = value_index + 1)
                        base_intermediate_bank[base_write_bank][
                            (value_index * 3
                             + 32'(base_write_frequency)) * 18 +: 18
                        ] <= clip18(base_rounded[value_index]);
                end

                dequant_overflow_valid <= dequant_write_valid;
                dequant_overflow_bank <= dequant_write_bank;
                pass1_overflow_valid <= pass1_write_valid;
                pass1_overflow_bank <= pass1_write_bank;
                back_overflow_valid <= back_s3_valid;
                back_overflow_bank <= back_s3_bank;
                if (dequant_overflow_valid && (|dequant_overflow_bits))
                    bank_saturated[dequant_overflow_bank] <= 1'b1;
                if (pass1_overflow_valid && (|pass1_overflow_bits))
                    bank_saturated[pass1_overflow_bank] <= 1'b1;
                if (back_overflow_valid && back_overflow_bit) begin
                    bank_saturated[back_overflow_bank] <= 1'b1;
                    if (back_active && (back_overflow_bank == back_bank))
                        saturated <= 1'b1;
                end
                pixel_valid <= back_s3_valid;
                if (back_s3_valid) begin
                    pixel_index <= back_s3_tag;
                    pixel_residual <= clip16(round_q14(back_sum3));
                    pixel_reference_residual <=
                        (back_s3_tag[2:0] == 3'd7)
                        ? clip16(round_q14(back_base_sum3))
                        : clip16(round_q14(back_sum3));
                    pixel_last <= (back_s3_tag == 6'd63);
                    pixel_ctu_index <= bank_ctu_index[back_s3_bank];
                    pixel_block_index <= bank_block_index[back_s3_bank];
                    pixel_plane <= bank_plane[back_s3_bank];
                    pixel_mode <= bank_mode[back_s3_bank];
                    back_overflow_bit <=
                        (round_q14(back_sum3) > 35'sd32767)
                     || (round_q14(back_sum3) < -35'sd32768);
                end

                if (issue_front_dequant) begin
                    if (front_issue == 6'd2)
                        front_state <= F_DEQ_DRAIN;
                    else
                        front_issue <= front_issue + 1'b1;
                end
                if ((front_state == F_DEQ_DRAIN)
                 && dequant_write_valid && (dequant_write_tag == 2'd2)) begin
                    front_state <= F_PASS1;
                    front_issue <= 6'd0;
                    for (value_index = 0; value_index < 16;
                         value_index = value_index + 1)
                        front_issue_pass1[value_index] <= 5'd0;
                end

                if (issue_front_pass1) begin
                    if (front_issue == 6'd31)
                        front_state <= F_PASS1_DRAIN;
                    else begin
                        front_issue <= front_issue + 1'b1;
                        for (value_index = 0; value_index < 16;
                             value_index = value_index + 1)
                            front_issue_pass1[value_index] <=
                                front_issue_pass1[value_index] + 1'b1;
                    end
                end
                if ((front_state == F_PASS1_DRAIN)
                 && pass1_write_valid && (pass1_write_tag == 6'd31)) begin
                    front_state <= F_BASE;
                    front_issue <= 6'd0;
                    base_dequant_row[0 +: 16] <=
                        dequantized_front[0 * 16 +: 16];
                    base_dequant_row[16 +: 16] <=
                        dequantized_front[8 * 16 +: 16];
                    base_dequant_row[32 +: 16] <= front_is_chroma
                        ? 16'sd0 : dequantized_front[16 * 16 +: 16];
                end

                if (issue_front_base) begin
                    if (front_issue == 6'd0) begin
                        base_dequant_row[0 +: 16] <=
                            dequantized_front[1 * 16 +: 16];
                        base_dequant_row[16 +: 16] <= front_is_chroma
                            ? 16'sd0 : dequantized_front[9 * 16 +: 16];
                        base_dequant_row[32 +: 16] <= 16'sd0;
                        front_issue <= front_issue + 1'b1;
                    end else if (front_issue == 6'd1) begin
                        base_dequant_row[0 +: 16] <= front_is_chroma
                            ? 16'sd0 : dequantized_front[2 * 16 +: 16];
                        base_dequant_row[16 +: 16] <= 16'sd0;
                        base_dequant_row[32 +: 16] <= 16'sd0;
                        front_issue <= front_issue + 1'b1;
                    end else begin
                        front_state <= F_BASE_DRAIN;
                    end
                end
                if ((front_state == F_BASE_DRAIN)
                 && base_write_valid && (base_write_frequency == 2)) begin
                    bank_ready[front_bank] <= 1'b1;
                    front_active <= 1'b0;
                    front_state <= F_IDLE;
                end

                if (issue_back_valid) begin
                    if (back_issue[2:0] == 3'd6)
                        base_edge_row <= base_intermediate_bank[back_bank][
                            32'(back_issue[5:3]) * 54 +: 54
                        ];
                    if (back_issue == 6'd63)
                        back_all_issued <= 1'b1;
                    else
                        back_issue <= back_issue + 1'b1;
                end
            end

            if (output_fire && pixel_last) begin
                pixel_valid <= 1'b0;
                bank_occupied[back_bank] <= 1'b0;
                back_active <= 1'b0;
                back_all_issued <= 1'b0;
                done <= 1'b1;
            end
        end
    end
endmodule
