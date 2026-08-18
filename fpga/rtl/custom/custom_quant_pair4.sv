module custom_quant_pair4 (
    input  logic                       clk,
    input  logic                       rst_n,
    input  logic                       clear,

    input  logic                       s_valid,
    output logic                       s_ready,
    input  logic                       s_quality24,
    input  logic                       s_table_id,
    input  logic [5:0]                 s_index,
    input  logic signed [15:0]         s_a0,
    input  logic signed [15:0]         s_a1,
    input  logic signed [15:0]         s_b0,
    input  logic signed [15:0]         s_b1,

    output logic                       m_valid,
    input  logic                       m_ready,
    output logic [5:0]                 m_index,
    output logic signed [11:0]         m_a0,
    output logic signed [11:0]         m_a1,
    output logic signed [11:0]         m_b0,
    output logic signed [11:0]         m_b1,
    output logic                       m_last,

    output logic                       busy,
    output logic                       input_error,
    output logic                       saturated
);
    logic lookup_valid;
    logic [5:0] lookup_index;
    logic lookup_sign_a0, lookup_sign_a1, lookup_sign_b0, lookup_sign_b1;
    logic [16:0] lookup_magnitude_a0, lookup_magnitude_a1;
    logic [16:0] lookup_magnitude_b0, lookup_magnitude_b1;

    logic correction_pending;
    logic [5:0] active_index;
    logic active_sign_a0, active_sign_a1, active_sign_b0, active_sign_b1;
    logic [17:0] active_numerator_a0, active_numerator_a1;
    logic [17:0] active_numerator_b0, active_numerator_b1;
    logic [7:0] active_divisor_0, active_divisor_1;

    logic result_pending;
    logic [5:0] result_index;
    logic result_sign_a0, result_sign_a1, result_sign_b0, result_sign_b1;
    logic [17:0] result_numerator_a0, result_numerator_a1;
    logic [17:0] result_numerator_b0, result_numerator_b1;
    logic [17:0] result_q0_a0, result_q0_a1;
    logic [17:0] result_q0_b0, result_q0_b1;

    logic [7:0] rom_divisor_0, rom_divisor_1;
    logic [17:0] rom_reciprocal_0, rom_reciprocal_1;
    logic [17:0] mac_operand_a0, mac_operand_a1;
    logic [17:0] mac_operand_b0, mac_operand_b1;
    logic [17:0] mac_factor_0, mac_factor_1;
    logic [35:0] mac_product_a0, mac_product_a1;
    logic [35:0] mac_product_b0, mac_product_b1;
    logic [17:0] reciprocal_q0_a0, reciprocal_q0_a1;
    logic [17:0] reciprocal_q0_b0, reciprocal_q0_b1;
    logic [17:0] result_magnitude_a0, result_magnitude_a1;
    logic [17:0] result_magnitude_b0, result_magnitude_b1;
    logic result_saturated;

    wire output_fire = result_pending && m_ready;
    wire reciprocal_issue = lookup_valid && !correction_pending
                                && (!result_pending || m_ready);
    wire correction_issue = correction_pending;
    wire input_fire = s_valid && s_ready;
    wire mac_enable = reciprocal_issue || correction_issue;

    function automatic logic [16:0] magnitude16(
        input logic signed [15:0] value
    );
        begin
            if (value < 0)
                magnitude16 = {1'b0, (~value + 1'b1)};
            else
                magnitude16 = {1'b0, value};
        end
    endfunction

    function automatic logic signed [11:0] signed_quantized(
        input logic sign,
        input logic [17:0] magnitude
    );
        logic signed [12:0] signed_value;
        begin
            if (sign) begin
                if (magnitude > 18'd2048)
                    signed_quantized = -12'sd2048;
                else begin
                    signed_value = -$signed({1'b0, magnitude[11:0]});
                    signed_quantized = signed_value[11:0];
                end
            end else if (magnitude > 18'd2047) begin
                signed_quantized = 12'sd2047;
            end else begin
                signed_quantized = $signed(magnitude[11:0]);
            end
        end
    endfunction

    assign s_ready = !lookup_valid || reciprocal_issue;
    assign m_valid = result_pending;
    assign m_index = result_index;
    assign m_last = result_index == 6'd62;
    assign m_a0 = signed_quantized(result_sign_a0, result_magnitude_a0);
    assign m_a1 = signed_quantized(result_sign_a1, result_magnitude_a1);
    assign m_b0 = signed_quantized(result_sign_b0, result_magnitude_b0);
    assign m_b1 = signed_quantized(result_sign_b1, result_magnitude_b1);
    assign busy = lookup_valid || correction_pending || result_pending;

    assign reciprocal_q0_a0 = mac_product_a0[35:18];
    assign reciprocal_q0_a1 = mac_product_a1[35:18];
    assign reciprocal_q0_b0 = mac_product_b0[35:18];
    assign reciprocal_q0_b1 = mac_product_b1[35:18];

    assign result_magnitude_a0 = result_q0_a0
        + ((mac_product_a0 <= {18'd0, result_numerator_a0}) ? 18'd1 : 18'd0);
    assign result_magnitude_a1 = result_q0_a1
        + ((mac_product_a1 <= {18'd0, result_numerator_a1}) ? 18'd1 : 18'd0);
    assign result_magnitude_b0 = result_q0_b0
        + ((mac_product_b0 <= {18'd0, result_numerator_b0}) ? 18'd1 : 18'd0);
    assign result_magnitude_b1 = result_q0_b1
        + ((mac_product_b1 <= {18'd0, result_numerator_b1}) ? 18'd1 : 18'd0);
    assign result_saturated =
        (result_magnitude_a0 > (result_sign_a0 ? 18'd2048 : 18'd2047))
        || (result_magnitude_a1 > (result_sign_a1 ? 18'd2048 : 18'd2047))
        || (result_magnitude_b0 > (result_sign_b0 ? 18'd2048 : 18'd2047))
        || (result_magnitude_b1 > (result_sign_b1 ? 18'd2048 : 18'd2047));

    always_comb begin
        if (correction_pending) begin
            mac_operand_a0 = reciprocal_q0_a0 + 1'b1;
            mac_operand_a1 = reciprocal_q0_a1 + 1'b1;
            mac_operand_b0 = reciprocal_q0_b0 + 1'b1;
            mac_operand_b1 = reciprocal_q0_b1 + 1'b1;
            mac_factor_0 = {10'd0, active_divisor_0};
            mac_factor_1 = {10'd0, active_divisor_1};
        end else begin
            mac_operand_a0 = lookup_magnitude_a0
                + {10'd0, rom_divisor_0[7:1]};
            mac_operand_a1 = lookup_magnitude_a1
                + {10'd0, rom_divisor_1[7:1]};
            mac_operand_b0 = lookup_magnitude_b0
                + {10'd0, rom_divisor_0[7:1]};
            mac_operand_b1 = lookup_magnitude_b1
                + {10'd0, rom_divisor_1[7:1]};
            mac_factor_0 = rom_reciprocal_0;
            mac_factor_1 = rom_reciprocal_1;
        end
    end

    custom_quant_table_rom table_rom (
        .clk(clk),
        .read_enable(input_fire),
        .read_address({s_quality24, s_table_id, s_index[5:1]}),
        .divisor_0(rom_divisor_0), .divisor_1(rom_divisor_1),
        .reciprocal_0(rom_reciprocal_0),
        .reciprocal_1(rom_reciprocal_1)
    );

    custom_quant_mac4 mac (
        .clk(clk), .enable(mac_enable),
        .operand_a0(mac_operand_a0), .operand_a1(mac_operand_a1),
        .operand_b0(mac_operand_b0), .operand_b1(mac_operand_b1),
        .factor_0(mac_factor_0), .factor_1(mac_factor_1),
        .product_a0(mac_product_a0), .product_a1(mac_product_a1),
        .product_b0(mac_product_b0), .product_b1(mac_product_b1)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            lookup_valid <= 1'b0;
            correction_pending <= 1'b0;
            result_pending <= 1'b0;
            input_error <= 1'b0;
            saturated <= 1'b0;
        end else if (clear) begin
            lookup_valid <= 1'b0;
            correction_pending <= 1'b0;
            result_pending <= 1'b0;
            input_error <= 1'b0;
            saturated <= 1'b0;
        end else begin
            if (input_fire) begin
                lookup_valid <= 1'b1;
                lookup_index <= s_index;
                lookup_sign_a0 <= s_a0 < 0;
                lookup_sign_a1 <= s_a1 < 0;
                lookup_sign_b0 <= s_b0 < 0;
                lookup_sign_b1 <= s_b1 < 0;
                lookup_magnitude_a0 <= magnitude16(s_a0);
                lookup_magnitude_a1 <= magnitude16(s_a1);
                lookup_magnitude_b0 <= magnitude16(s_b0);
                lookup_magnitude_b1 <= magnitude16(s_b1);
                if (s_index[0])
                    input_error <= 1'b1;
            end else if (reciprocal_issue) begin
                lookup_valid <= 1'b0;
            end

            if (reciprocal_issue) begin
                correction_pending <= 1'b1;
                active_index <= lookup_index;
                active_sign_a0 <= lookup_sign_a0;
                active_sign_a1 <= lookup_sign_a1;
                active_sign_b0 <= lookup_sign_b0;
                active_sign_b1 <= lookup_sign_b1;
                active_numerator_a0 <= mac_operand_a0;
                active_numerator_a1 <= mac_operand_a1;
                active_numerator_b0 <= mac_operand_b0;
                active_numerator_b1 <= mac_operand_b1;
                active_divisor_0 <= rom_divisor_0;
                active_divisor_1 <= rom_divisor_1;
            end

            if (correction_issue) begin
                correction_pending <= 1'b0;
                result_pending <= 1'b1;
                result_index <= active_index;
                result_sign_a0 <= active_sign_a0;
                result_sign_a1 <= active_sign_a1;
                result_sign_b0 <= active_sign_b0;
                result_sign_b1 <= active_sign_b1;
                result_numerator_a0 <= active_numerator_a0;
                result_numerator_a1 <= active_numerator_a1;
                result_numerator_b0 <= active_numerator_b0;
                result_numerator_b1 <= active_numerator_b1;
                result_q0_a0 <= reciprocal_q0_a0;
                result_q0_a1 <= reciprocal_q0_a1;
                result_q0_b0 <= reciprocal_q0_b0;
                result_q0_b1 <= reciprocal_q0_b1;
            end else if (output_fire) begin
                result_pending <= 1'b0;
                if (result_saturated)
                    saturated <= 1'b1;
            end
        end
    end
endmodule
