module custom_quant_pair4 (
    input  logic                       clk,
    input  logic                       rst_n,
    input  logic                       clear,

    input  logic                       s_valid,
    output logic                       s_ready,
    input  logic                       s_quality24,
    input  logic                       s_table_id,
    input  logic [5:0]                 s_index,
    input  logic signed [15:0]        s_a0,
    input  logic signed [15:0]        s_a1,
    input  logic signed [15:0]        s_b0,
    input  logic signed [15:0]        s_b1,

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

    logic product_valid;
    logic [5:0] product_index;
    logic product_sign_a0, product_sign_a1, product_sign_b0, product_sign_b1;
    logic [4:0] product_shift_0, product_shift_1;

    logic final_pending;
    logic [5:0] final_index;
    logic final_sign_a0, final_sign_a1, final_sign_b0, final_sign_b1;
    logic [17:0] final_magnitude_a0, final_magnitude_a1;
    logic [17:0] final_magnitude_b0, final_magnitude_b1;

    logic [7:0] rom_divisor_0, rom_divisor_1;
    logic [15:0] rom_multiplier_0, rom_multiplier_1;
    logic [4:0] rom_shift_0, rom_shift_1;
    logic [15:0] mac_operand_a0, mac_operand_a1;
    logic [15:0] mac_operand_b0, mac_operand_b1;
    logic [31:0] mac_product_a0, mac_product_a1;
    logic [31:0] mac_product_b0, mac_product_b1;
    logic [31:0] shifted_product_a0, shifted_product_a1;
    logic [31:0] shifted_product_b0, shifted_product_b1;
    logic result_saturated;

    wire output_fire = final_pending && m_ready;
    wire final_slot_ready = !final_pending || m_ready;
    wire product_fire = product_valid && final_slot_ready;
    wire product_slot_ready = !product_valid || product_fire;
    wire multiply_issue = lookup_valid && product_slot_ready;
    wire input_fire = s_valid && s_ready;

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

    assign s_ready = !lookup_valid || multiply_issue;
    assign m_valid = final_pending;
    assign m_index = final_index;
    assign m_last = final_index == 6'd62;
    assign m_a0 = signed_quantized(final_sign_a0, final_magnitude_a0);
    assign m_a1 = signed_quantized(final_sign_a1, final_magnitude_a1);
    assign m_b0 = signed_quantized(final_sign_b0, final_magnitude_b0);
    assign m_b1 = signed_quantized(final_sign_b1, final_magnitude_b1);
    assign busy = lookup_valid || product_valid || final_pending;

    assign mac_operand_a0 = lookup_magnitude_a0[15:0]
        + {8'd0, rom_divisor_0[7:1]};
    assign mac_operand_a1 = lookup_magnitude_a1[15:0]
        + {8'd0, rom_divisor_1[7:1]};
    assign mac_operand_b0 = lookup_magnitude_b0[15:0]
        + {8'd0, rom_divisor_0[7:1]};
    assign mac_operand_b1 = lookup_magnitude_b1[15:0]
        + {8'd0, rom_divisor_1[7:1]};

    assign shifted_product_a0 = mac_product_a0 >> product_shift_0;
    assign shifted_product_a1 = mac_product_a1 >> product_shift_1;
    assign shifted_product_b0 = mac_product_b0 >> product_shift_0;
    assign shifted_product_b1 = mac_product_b1 >> product_shift_1;
    assign result_saturated =
        (shifted_product_a0 > (product_sign_a0 ? 32'd2048 : 32'd2047))
        || (shifted_product_a1 > (product_sign_a1 ? 32'd2048 : 32'd2047))
        || (shifted_product_b0 > (product_sign_b0 ? 32'd2048 : 32'd2047))
        || (shifted_product_b1 > (product_sign_b1 ? 32'd2048 : 32'd2047));

    custom_quant_table_rom table_rom (
        .clk(clk), .read_enable(input_fire),
        .read_address({s_quality24, s_table_id, s_index[5:1]}),
        .divisor_0(rom_divisor_0), .divisor_1(rom_divisor_1),
        .multiplier_0(rom_multiplier_0),
        .multiplier_1(rom_multiplier_1),
        .shift_0(rom_shift_0), .shift_1(rom_shift_1)
    );

    custom_quant_mac4 mac (
        .clk(clk), .enable(multiply_issue),
        .operand_a0(mac_operand_a0), .operand_a1(mac_operand_a1),
        .operand_b0(mac_operand_b0), .operand_b1(mac_operand_b1),
        .factor_0(rom_multiplier_0), .factor_1(rom_multiplier_1),
        .product_a0(mac_product_a0), .product_a1(mac_product_a1),
        .product_b0(mac_product_b0), .product_b1(mac_product_b1)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            lookup_valid <= 1'b0;
            product_valid <= 1'b0;
            final_pending <= 1'b0;
            input_error <= 1'b0;
            saturated <= 1'b0;
        end else if (clear) begin
            lookup_valid <= 1'b0;
            product_valid <= 1'b0;
            final_pending <= 1'b0;
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
            end else if (multiply_issue) begin
                lookup_valid <= 1'b0;
            end

            if (multiply_issue) begin
                product_valid <= 1'b1;
                product_index <= lookup_index;
                product_sign_a0 <= lookup_sign_a0;
                product_sign_a1 <= lookup_sign_a1;
                product_sign_b0 <= lookup_sign_b0;
                product_sign_b1 <= lookup_sign_b1;
                product_shift_0 <= rom_shift_0;
                product_shift_1 <= rom_shift_1;
            end else if (product_fire) begin
                product_valid <= 1'b0;
            end

            if (product_fire) begin
                final_pending <= 1'b1;
                final_index <= product_index;
                final_sign_a0 <= product_sign_a0;
                final_sign_a1 <= product_sign_a1;
                final_sign_b0 <= product_sign_b0;
                final_sign_b1 <= product_sign_b1;
                final_magnitude_a0 <= shifted_product_a0[17:0];
                final_magnitude_a1 <= shifted_product_a1[17:0];
                final_magnitude_b0 <= shifted_product_b0[17:0];
                final_magnitude_b1 <= shifted_product_b1[17:0];
                if (result_saturated)
                    saturated <= 1'b1;
            end else if (output_fire) begin
                final_pending <= 1'b0;
            end
        end
    end
endmodule
