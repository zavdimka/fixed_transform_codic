`ifndef RECEIVER_VLC_AC_DECODE_FILE
`define RECEIVER_VLC_AC_DECODE_FILE "../rtl/receiver/receiver_vlc_ac_decode_symbols.hex"
`endif

module receiver_base_entropy_decoder #(
    parameter integer CTU_COUNT = 80
) (
    input  logic         clk,
    input  logic         rst_n,

    input  logic         record_valid,
    output logic         record_ready,
    input  logic [15:0]  display_frame_id,
    input  logic [7:0]   stripe_id,
    input  logic [7:0]   quality,
    input  logic [7:0]   fragment_index,
    input  logic [7:0]   fragment_count,
    input  logic [7:0]   record_flags,
    input  logic [15:0]  payload_length,
    input  logic [7:0]   payload_data,
    input  logic         payload_valid,
    output logic         payload_ready,
    input  logic         payload_last,

    output logic         block_valid,
    input  logic         block_ready,
    output logic [6:0]   block_ctu_index,
    output logic [2:0]   block_index,
    output logic [1:0]   block_plane,
    output logic [1:0]   block_mode,
    output logic [71:0]  block_coefficients,

    output logic         stripe_done,
    output logic [15:0]  stripe_frame_id,
    output logic [7:0]   completed_stripe_id,
    output logic [7:0]   stripe_quality,
    output logic [31:0]  completed_stripe_count,
    output logic [31:0]  rejected_stripe_count,
    output logic [31:0]  syntax_error_count
);
    localparam logic [3:0] S_IDLE         = 4'd0;
    localparam logic [3:0] S_MODE         = 4'd1;
    localparam logic [3:0] S_BLOCK_START  = 4'd2;
    localparam logic [3:0] S_DC_HUFF      = 4'd3;
    localparam logic [3:0] S_DC_AMPLITUDE = 4'd4;
    localparam logic [3:0] S_AC_PREFIX    = 4'd5;
    localparam logic [3:0] S_AC_HUFF      = 4'd6;
    localparam logic [3:0] S_AC_ROM_WAIT  = 4'd7;
    localparam logic [3:0] S_AC_SYMBOL    = 4'd8;
    localparam logic [3:0] S_AC_AMPLITUDE = 4'd9;
    localparam logic [3:0] S_BLOCK_OUTPUT = 4'd10;
    localparam logic [3:0] S_ERROR        = 4'd11;

    logic [3:0] state;
    logic stripe_active;
    logic current_record_active;
    logic current_record_accept;
    logic current_record_final;
    logic [15:0] current_bytes_left;
    logic [7:0] expected_fragment_index;
    logic [7:0] active_fragment_count;
    logic [15:0] active_frame_id;
    logic [7:0] active_stripe_id;
    logic [7:0] active_quality;

    logic [7:0] bit_byte;
    logic [3:0] bits_remaining;
    logic byte_valid;
    logic byte_stream_last;
    logic stream_end_seen;

    logic mode_first_bit;
    logic mode_bit_count;
    logic [15:0] huffman_code;
    logic [4:0] huffman_length;
    logic [3:0] amplitude_size;
    logic [9:0] amplitude_bits;
    logic [3:0] amplitude_count;
    logic [2:0] ac_position;
    logic [2:0] ac_target;
    logic [8:0] ac_rom_address;
    logic [7:0] ac_rom_data;
    logic signed [11:0] coefficients [0:5];

    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    logic [7:0] ac_symbol_order [0:511];
    initial $readmemh(`RECEIVER_VLC_AC_DECODE_FILE, ac_symbol_order);
    always_ff @(posedge clk)
        ac_rom_data <= ac_symbol_order[ac_rom_address];

    wire table_id = (block_index >= 3'd4);
    wire [2:0] segment_length = table_id ? 3'd2 : 3'd5;
    wire need_bit = (state == S_MODE) || (state == S_DC_HUFF)
                  || (state == S_DC_AMPLITUDE) || (state == S_AC_PREFIX)
                  || (state == S_AC_HUFF) || (state == S_AC_AMPLITUDE);
    wire bit_available = byte_valid && (bits_remaining != 0);
    wire [2:0] input_bit_index = bits_remaining[2:0] - 1'b1;
    wire input_bit = bit_byte[input_bit_index];
    wire bit_fire = need_bit && bit_available;
    wire input_bit_is_last = byte_stream_last && (bits_remaining == 1);
    wire payload_fire = payload_valid && payload_ready;

    assign record_ready = !current_record_active;
    assign payload_ready = current_record_active
                         && (!current_record_accept || !byte_valid);
    assign block_valid = (state == S_BLOCK_OUTPUT);
    assign block_plane = (block_index < 3'd4) ? 2'd0
                       : (block_index == 3'd4) ? 2'd1 : 2'd2;
    assign block_coefficients = {
        coefficients[5], coefficients[4], coefficients[3],
        coefficients[2], coefficients[1], coefficients[0]
    };

    // {first canonical code, first symbol-order index, code count}.
    function automatic [31:0] canonical_meta(
        input logic is_ac,
        input logic table_select,
        input logic [4:0] length
    );
        begin
            canonical_meta = 32'd0;
            if (!is_ac && !table_select) begin
                case (length)
                    2: canonical_meta = {16'h0000, 8'd0, 8'd1};
                    3: canonical_meta = {16'h0002, 8'd1, 8'd5};
                    4: canonical_meta = {16'h000E, 8'd6, 8'd1};
                    5: canonical_meta = {16'h001E, 8'd7, 8'd1};
                    6: canonical_meta = {16'h003E, 8'd8, 8'd1};
                    7: canonical_meta = {16'h007E, 8'd9, 8'd1};
                    8: canonical_meta = {16'h00FE, 8'd10, 8'd1};
                    9: canonical_meta = {16'h01FE, 8'd11, 8'd1};
                    default: canonical_meta = 32'd0;
                endcase
            end else if (!is_ac) begin
                case (length)
                    2: canonical_meta = {16'h0000, 8'd0, 8'd3};
                    3: canonical_meta = {16'h0006, 8'd3, 8'd1};
                    4: canonical_meta = {16'h000E, 8'd4, 8'd1};
                    5: canonical_meta = {16'h001E, 8'd5, 8'd1};
                    6: canonical_meta = {16'h003E, 8'd6, 8'd1};
                    7: canonical_meta = {16'h007E, 8'd7, 8'd1};
                    8: canonical_meta = {16'h00FE, 8'd8, 8'd1};
                    9: canonical_meta = {16'h01FE, 8'd9, 8'd1};
                    10: canonical_meta = {16'h03FE, 8'd10, 8'd1};
                    11: canonical_meta = {16'h07FE, 8'd11, 8'd1};
                    default: canonical_meta = 32'd0;
                endcase
            end else if (!table_select) begin
                case (length)
                    2: canonical_meta = {16'h0000, 8'd0, 8'd2};
                    3: canonical_meta = {16'h0004, 8'd2, 8'd1};
                    4: canonical_meta = {16'h000A, 8'd3, 8'd3};
                    5: canonical_meta = {16'h001A, 8'd6, 8'd3};
                    6: canonical_meta = {16'h003A, 8'd9, 8'd2};
                    7: canonical_meta = {16'h0078, 8'd11, 8'd4};
                    8: canonical_meta = {16'h00F8, 8'd15, 8'd3};
                    9: canonical_meta = {16'h01F6, 8'd18, 8'd5};
                    10: canonical_meta = {16'h03F6, 8'd23, 8'd5};
                    11: canonical_meta = {16'h07F6, 8'd28, 8'd4};
                    12: canonical_meta = {16'h0FF4, 8'd32, 8'd4};
                    15: canonical_meta = {16'h7FC0, 8'd36, 8'd1};
                    16: canonical_meta = {16'hFF82, 8'd37, 8'd125};
                    default: canonical_meta = 32'd0;
                endcase
            end else begin
                case (length)
                    2: canonical_meta = {16'h0000, 8'd0, 8'd2};
                    3: canonical_meta = {16'h0004, 8'd2, 8'd1};
                    4: canonical_meta = {16'h000A, 8'd3, 8'd2};
                    5: canonical_meta = {16'h0018, 8'd5, 8'd4};
                    6: canonical_meta = {16'h0038, 8'd9, 8'd4};
                    7: canonical_meta = {16'h0078, 8'd13, 8'd3};
                    8: canonical_meta = {16'h00F6, 8'd16, 8'd4};
                    9: canonical_meta = {16'h01F4, 8'd20, 8'd7};
                    10: canonical_meta = {16'h03F6, 8'd27, 8'd5};
                    11: canonical_meta = {16'h07F6, 8'd32, 8'd4};
                    12: canonical_meta = {16'h0FF4, 8'd36, 8'd4};
                    14: canonical_meta = {16'h3FE0, 8'd40, 8'd1};
                    15: canonical_meta = {16'h7FC2, 8'd41, 8'd2};
                    16: canonical_meta = {16'hFF88, 8'd43, 8'd119};
                    default: canonical_meta = 32'd0;
                endcase
            end
        end
    endfunction

    function automatic signed [11:0] amplitude_value(
        input logic [10:0] raw_value,
        input logic [3:0] size
    );
        logic signed [11:0] work;
        begin
            if (size == 0)
                work = 12'sd0;
            else if (raw_value[size - 1'b1])
                work = $signed({1'b0, raw_value});
            else
                work = $signed({1'b0, raw_value})
                     - $signed((12'd1 << size) - 1'b1);
            amplitude_value = work;
        end
    endfunction

    logic [16:0] next_huffman_code;
    logic [4:0] next_huffman_length;
    logic [31:0] huffman_meta;
    logic [16:0] huffman_offset;
    logic huffman_match;
    wire [3:0] decoded_dc_size = huffman_meta[11:8]
                                 + huffman_offset[3:0];
    always_comb begin
        next_huffman_code = {1'b0, huffman_code} << 1;
        next_huffman_code[0] = input_bit;
        next_huffman_length = huffman_length + 1'b1;
        huffman_meta = canonical_meta(state == S_AC_HUFF, table_id,
                                      next_huffman_length);
        huffman_offset = next_huffman_code - {1'b0, huffman_meta[31:16]};
        huffman_match = (huffman_meta[7:0] != 0)
                     && (next_huffman_code >= {1'b0, huffman_meta[31:16]})
                     && (huffman_offset < {9'd0, huffman_meta[7:0]});
    end

    integer coefficient_index;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE;
            stripe_active <= 1'b0;
            current_record_active <= 1'b0;
            current_record_accept <= 1'b0;
            current_record_final <= 1'b0;
            current_bytes_left <= 16'd0;
            expected_fragment_index <= 8'd0;
            active_fragment_count <= 8'd0;
            active_frame_id <= 16'd0;
            active_stripe_id <= 8'd0;
            active_quality <= 8'd0;
            bit_byte <= 8'd0;
            bits_remaining <= 4'd0;
            byte_valid <= 1'b0;
            byte_stream_last <= 1'b0;
            stream_end_seen <= 1'b0;
            mode_first_bit <= 1'b0;
            mode_bit_count <= 1'b0;
            huffman_code <= 16'd0;
            huffman_length <= 5'd0;
            amplitude_size <= 4'd0;
            amplitude_bits <= 10'd0;
            amplitude_count <= 4'd0;
            ac_position <= 3'd0;
            ac_target <= 3'd0;
            ac_rom_address <= 9'd0;
            block_ctu_index <= 7'd0;
            block_index <= 3'd0;
            block_mode <= 2'd0;
            stripe_done <= 1'b0;
            stripe_frame_id <= 16'd0;
            completed_stripe_id <= 8'd0;
            stripe_quality <= 8'd0;
            completed_stripe_count <= 32'd0;
            rejected_stripe_count <= 32'd0;
            syntax_error_count <= 32'd0;
            for (coefficient_index = 0; coefficient_index < 6;
                 coefficient_index = coefficient_index + 1)
                coefficients[coefficient_index] <= 12'sd0;
        end else begin
            stripe_done <= 1'b0;

            if (record_valid && record_ready) begin
                current_record_active <= 1'b1;
                current_bytes_left <= payload_length;
                current_record_final <=
                    (fragment_index + 1'b1 == fragment_count);
                current_record_accept <= 1'b0;

                if ((fragment_count == 0) || (fragment_index >= fragment_count)
                    || (payload_length == 0)
                    || ((fragment_index + 1'b1 != fragment_count)
                        && (record_flags != 0))
                    || ((fragment_index + 1'b1 == fragment_count)
                        && (record_flags[7:3] != 0))) begin
                    if (stripe_active) begin
                        stripe_active <= 1'b0;
                        state <= S_ERROR;
                    end
                    rejected_stripe_count <= rejected_stripe_count + 1'b1;
                end else if (fragment_index == 0) begin
                    if (stripe_active)
                        rejected_stripe_count <= rejected_stripe_count + 1'b1;
                    stripe_active <= 1'b1;
                    current_record_accept <= 1'b1;
                    expected_fragment_index <= 8'd1;
                    active_fragment_count <= fragment_count;
                    active_frame_id <= display_frame_id;
                    active_stripe_id <= stripe_id;
                    active_quality <= quality;
                    stream_end_seen <= 1'b0;
                    byte_valid <= 1'b0;
                    state <= S_MODE;
                    mode_first_bit <= 1'b0;
                    mode_bit_count <= 1'b0;
                    block_ctu_index <= 7'd0;
                    block_index <= 3'd0;
                end else if (stripe_active
                             && (display_frame_id == active_frame_id)
                             && (stripe_id == active_stripe_id)
                             && (quality == active_quality)
                             && (fragment_count == active_fragment_count)
                             && (fragment_index == expected_fragment_index)) begin
                    current_record_accept <= 1'b1;
                    expected_fragment_index <= expected_fragment_index + 1'b1;
                end else begin
                    stripe_active <= 1'b0;
                    state <= S_ERROR;
                    rejected_stripe_count <= rejected_stripe_count + 1'b1;
                end
            end

            if (payload_fire) begin
                if (current_bytes_left != 0)
                    current_bytes_left <= current_bytes_left - 1'b1;
                if (current_record_accept) begin
                    bit_byte <= payload_data;
                    byte_valid <= 1'b1;
                    bits_remaining <= (payload_last && current_record_final)
                                    ? ({1'b0, record_flags[2:0]} + 1'b1)
                                    : 4'd8;
                    byte_stream_last <= payload_last && current_record_final;
                end

                if (payload_last) begin
                    current_record_active <= 1'b0;
                    current_record_accept <= 1'b0;
                    if (current_bytes_left != 1) begin
                        stripe_active <= 1'b0;
                        state <= S_ERROR;
                        rejected_stripe_count <= rejected_stripe_count + 1'b1;
                    end
                end else if (current_bytes_left == 1) begin
                    current_record_accept <= 1'b0;
                    stripe_active <= 1'b0;
                    state <= S_ERROR;
                    rejected_stripe_count <= rejected_stripe_count + 1'b1;
                end
            end

            if (bit_fire) begin
                if (bits_remaining == 1)
                    byte_valid <= 1'b0;
                bits_remaining <= bits_remaining - 1'b1;
                if (input_bit_is_last)
                    stream_end_seen <= 1'b1;

                case (state)
                    S_MODE: begin
                        if (mode_bit_count) begin
                            block_mode <= {mode_first_bit, input_bit};
                            mode_bit_count <= 1'b0;
                            state <= S_BLOCK_START;
                        end else begin
                            mode_first_bit <= input_bit;
                            mode_bit_count <= 1'b1;
                        end
                    end

                    S_DC_HUFF: begin
                        if (huffman_match) begin
                            amplitude_size <= decoded_dc_size;
                            amplitude_bits <= 10'd0;
                            amplitude_count <= 4'd0;
                            huffman_code <= 16'd0;
                            huffman_length <= 5'd0;
                            if ((huffman_meta[15:8]
                                 + huffman_offset[7:0]) == 0) begin
                                coefficients[0] <= 12'sd0;
                                state <= table_id ? S_AC_HUFF : S_AC_PREFIX;
                            end else begin
                                state <= S_DC_AMPLITUDE;
                            end
                        end else if (next_huffman_length >= 5'd16) begin
                            state <= S_ERROR;
                            stripe_active <= 1'b0;
                            syntax_error_count <= syntax_error_count + 1'b1;
                            rejected_stripe_count <= rejected_stripe_count + 1'b1;
                        end else begin
                            huffman_code <= next_huffman_code[15:0];
                            huffman_length <= next_huffman_length;
                        end
                    end

                    S_DC_AMPLITUDE: begin
                        amplitude_bits <= {amplitude_bits[8:0], input_bit};
                        if (amplitude_count + 1'b1 == amplitude_size) begin
                            coefficients[0] <= amplitude_value(
                                {amplitude_bits, input_bit}, amplitude_size
                            );
                            state <= table_id ? S_AC_HUFF : S_AC_PREFIX;
                            huffman_code <= 16'd0;
                            huffman_length <= 5'd0;
                        end else begin
                            amplitude_count <= amplitude_count + 1'b1;
                        end
                    end

                    S_AC_PREFIX: begin
                        huffman_code <= 16'd0;
                        huffman_length <= 5'd0;
                        if (input_bit)
                            state <= S_AC_HUFF;
                        else
                            state <= S_BLOCK_OUTPUT;
                    end

                    S_AC_HUFF: begin
                        if (huffman_match) begin
                            ac_rom_address <= {table_id,
                                huffman_meta[15:8] + huffman_offset[7:0]};
                            huffman_code <= 16'd0;
                            huffman_length <= 5'd0;
                            state <= S_AC_ROM_WAIT;
                        end else if (next_huffman_length >= 5'd16) begin
                            state <= S_ERROR;
                            stripe_active <= 1'b0;
                            syntax_error_count <= syntax_error_count + 1'b1;
                            rejected_stripe_count <= rejected_stripe_count + 1'b1;
                        end else begin
                            huffman_code <= next_huffman_code[15:0];
                            huffman_length <= next_huffman_length;
                        end
                    end

                    S_AC_AMPLITUDE: begin
                        amplitude_bits <= {amplitude_bits[8:0], input_bit};
                        if (amplitude_count + 1'b1 == amplitude_size) begin
                            coefficients[ac_target + 1'b1] <= amplitude_value(
                                {amplitude_bits, input_bit}, amplitude_size
                            );
                            ac_position <= ac_target + 1'b1;
                            huffman_code <= 16'd0;
                            huffman_length <= 5'd0;
                            if (ac_target + 1'b1 == segment_length)
                                state <= S_BLOCK_OUTPUT;
                            else
                                state <= S_AC_HUFF;
                        end else begin
                            amplitude_count <= amplitude_count + 1'b1;
                        end
                    end
                    default: begin end
                endcase
            end

            if (state == S_BLOCK_START) begin
                for (coefficient_index = 0; coefficient_index < 6;
                     coefficient_index = coefficient_index + 1)
                    coefficients[coefficient_index] <= 12'sd0;
                ac_position <= 3'd0;
                huffman_code <= 16'd0;
                huffman_length <= 5'd0;
                state <= S_DC_HUFF;
            end

            if (state == S_AC_ROM_WAIT) begin
                state <= S_AC_SYMBOL;
            end

            if (state == S_AC_SYMBOL) begin
                if (ac_rom_data == 8'h00) begin
                    state <= S_BLOCK_OUTPUT;
                end else if ((ac_rom_data == 8'hF0)
                             || (ac_rom_data[3:0] == 0)
                             || (ac_position + ac_rom_data[7:4]
                                 >= {1'b0, segment_length})) begin
                    state <= S_ERROR;
                    stripe_active <= 1'b0;
                    syntax_error_count <= syntax_error_count + 1'b1;
                    rejected_stripe_count <= rejected_stripe_count + 1'b1;
                end else begin
                    ac_target <= ac_position + ac_rom_data[6:4];
                    amplitude_size <= ac_rom_data[3:0];
                    amplitude_bits <= 10'd0;
                    amplitude_count <= 4'd0;
                    state <= S_AC_AMPLITUDE;
                end
            end

            if ((state == S_BLOCK_OUTPUT) && block_ready) begin
                if ((block_index == 3'd5)
                    && (block_ctu_index == 7'(CTU_COUNT - 1))) begin
                    if (stream_end_seen) begin
                        stripe_done <= 1'b1;
                        stripe_frame_id <= active_frame_id;
                        completed_stripe_id <= active_stripe_id;
                        stripe_quality <= active_quality;
                        completed_stripe_count <= completed_stripe_count + 1'b1;
                    end else begin
                        syntax_error_count <= syntax_error_count + 1'b1;
                        rejected_stripe_count <= rejected_stripe_count + 1'b1;
                    end
                    stripe_active <= 1'b0;
                    state <= S_IDLE;
                end else if (block_index == 3'd5) begin
                    block_ctu_index <= block_ctu_index + 1'b1;
                    block_index <= 3'd0;
                    state <= S_MODE;
                    mode_first_bit <= 1'b0;
                    mode_bit_count <= 1'b0;
                end else begin
                    block_index <= block_index + 1'b1;
                    state <= S_BLOCK_START;
                end
            end

            // A final fragment that runs out before a complete stripe is a
            // syntax error. Waiting between non-final fragments is legal.
            if (stream_end_seen && !byte_valid && need_bit && !bit_fire) begin
                state <= S_ERROR;
                stripe_active <= 1'b0;
                stream_end_seen <= 1'b0;
                syntax_error_count <= syntax_error_count + 1'b1;
                rejected_stripe_count <= rejected_stripe_count + 1'b1;
            end

            if ((state == S_ERROR) && !current_record_active) begin
                state <= S_IDLE;
                byte_valid <= 1'b0;
                stream_end_seen <= 1'b0;
            end
        end
    end
endmodule
