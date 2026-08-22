`ifndef RECEIVER_VLC_AC_DECODE_FILE
`define RECEIVER_VLC_AC_DECODE_FILE "../rtl/receiver/receiver_vlc_ac_decode_symbols.hex"
`endif

module receiver_enhancement_entropy_decoder #(
    parameter integer CTU_COUNT = 80
) (
    input  logic               clk,
    input  logic               rst_n,

    input  logic               record_valid,
    output logic               record_ready,
    input  logic [15:0]        display_frame_id,
    input  logic [7:0]         stripe_id,
    input  logic [7:0]         quality,
    input  logic [7:0]         fragment_index,
    input  logic [7:0]         fragment_count,
    input  logic [7:0]         record_flags,
    input  logic [15:0]        payload_length,
    input  logic [7:0]         payload_data,
    input  logic               payload_valid,
    output logic               payload_ready,
    input  logic               payload_last,

    // Ordered sparse event stream. Every block emits START, zero or more
    // COEFFICIENT events, and END. scan_index is the complete 0..63 layered
    // scan index, not the index relative to the enhancement segment.
    output logic               event_valid,
    input  logic               event_ready,
    output logic [1:0]         event_kind,
    output logic [6:0]         event_ctu_index,
    output logic [2:0]         event_block_index,
    output logic [1:0]         event_plane,
    output logic [5:0]         event_scan_index,
    output logic signed [11:0] event_coefficient,
    output logic [7:0]         event_quality,
    output logic [15:0]        event_frame_id,
    output logic [7:0]         event_stripe_id,

    output logic [31:0]        completed_stripe_count,
    output logic [31:0]        rejected_stripe_count,
    output logic [31:0]        syntax_error_count
);
    localparam logic [1:0] EVENT_START = 2'd0;
    localparam logic [1:0] EVENT_COEFFICIENT = 2'd1;
    localparam logic [1:0] EVENT_END = 2'd2;

    localparam logic [3:0] S_IDLE = 4'd0;
    localparam logic [3:0] S_BLOCK_START = 4'd1;
    localparam logic [3:0] S_PRESENCE = 4'd2;
    localparam logic [3:0] S_AC_HUFF = 4'd3;
    localparam logic [3:0] S_AC_ROM_WAIT = 4'd4;
    localparam logic [3:0] S_AC_SYMBOL = 4'd5;
    localparam logic [3:0] S_AC_AMPLITUDE = 4'd6;
    localparam logic [3:0] S_COEFFICIENT = 4'd7;
    localparam logic [3:0] S_BLOCK_END = 4'd8;
    localparam logic [3:0] S_ERROR = 4'd9;

    logic [3:0] state;
    logic stripe_active, current_record_active, current_record_accept;
    logic current_record_final;
    logic [15:0] current_bytes_left;
    logic [7:0] expected_fragment_index, active_fragment_count;
    logic [15:0] active_frame_id;
    logic [7:0] active_stripe_id, active_quality;

    logic [7:0] bit_byte;
    logic [3:0] bits_remaining;
    logic [2:0] bit_position;
    logic byte_valid, byte_stream_last, stream_end_seen;

    logic [15:0] huffman_code;
    logic [4:0] huffman_length;
    logic [8:0] ac_rom_address;
    logic [7:0] ac_rom_data;
    logic [5:0] segment_position, coefficient_target;
    logic [3:0] amplitude_size, amplitude_count;
    logic [9:0] amplitude_bits;
    logic signed [11:0] coefficient_value;

    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    logic [7:0] ac_symbol_order [0:511];
    initial $readmemh(`RECEIVER_VLC_AC_DECODE_FILE, ac_symbol_order);
    always_ff @(posedge clk)
        ac_rom_data <= ac_symbol_order[ac_rom_address];

    wire table_id = (event_block_index >= 3'd4);
    wire [5:0] segment_length = table_id ? 6'd61 : 6'd58;
    wire [5:0] base_count = table_id ? 6'd3 : 6'd6;
    wire need_bit = (state == S_PRESENCE) || (state == S_AC_HUFF)
                 || (state == S_AC_AMPLITUDE);
    wire bit_available = byte_valid && (bits_remaining != 0);
    wire input_bit = bit_byte[bit_position];
    wire bit_fire = need_bit && bit_available;
    wire input_bit_is_last = byte_stream_last && (bits_remaining == 1);
    wire payload_fire = payload_valid && payload_ready;
    wire event_fire = event_valid && event_ready;

    assign record_ready = !current_record_active;
    assign payload_ready = current_record_active
                         && (!current_record_accept || !byte_valid);
    assign event_valid = (state == S_BLOCK_START)
                      || (state == S_COEFFICIENT)
                      || (state == S_BLOCK_END);
    assign event_kind = (state == S_BLOCK_START) ? EVENT_START
                      : (state == S_COEFFICIENT) ? EVENT_COEFFICIENT
                      : EVENT_END;
    assign event_plane = (event_block_index < 3'd4) ? 2'd0
                       : (event_block_index == 3'd4) ? 2'd1 : 2'd2;
    assign event_scan_index = base_count + coefficient_target;
    assign event_coefficient = coefficient_value;
    assign event_quality = active_quality;
    assign event_frame_id = active_frame_id;
    assign event_stripe_id = active_stripe_id;

    function automatic [31:0] canonical_ac_meta(
        input logic table_select,
        input logic [4:0] length
    );
        begin
            canonical_ac_meta = 32'd0;
            if (!table_select) begin
                case (length)
                    2: canonical_ac_meta = {16'h0000, 8'd0, 8'd2};
                    3: canonical_ac_meta = {16'h0004, 8'd2, 8'd1};
                    4: canonical_ac_meta = {16'h000A, 8'd3, 8'd3};
                    5: canonical_ac_meta = {16'h001A, 8'd6, 8'd3};
                    6: canonical_ac_meta = {16'h003A, 8'd9, 8'd2};
                    7: canonical_ac_meta = {16'h0078, 8'd11, 8'd4};
                    8: canonical_ac_meta = {16'h00F8, 8'd15, 8'd3};
                    9: canonical_ac_meta = {16'h01F6, 8'd18, 8'd5};
                    10: canonical_ac_meta = {16'h03F6, 8'd23, 8'd5};
                    11: canonical_ac_meta = {16'h07F6, 8'd28, 8'd4};
                    12: canonical_ac_meta = {16'h0FF4, 8'd32, 8'd4};
                    15: canonical_ac_meta = {16'h7FC0, 8'd36, 8'd1};
                    16: canonical_ac_meta = {16'hFF82, 8'd37, 8'd125};
                    default: canonical_ac_meta = 32'd0;
                endcase
            end else begin
                case (length)
                    2: canonical_ac_meta = {16'h0000, 8'd0, 8'd2};
                    3: canonical_ac_meta = {16'h0004, 8'd2, 8'd1};
                    4: canonical_ac_meta = {16'h000A, 8'd3, 8'd2};
                    5: canonical_ac_meta = {16'h0018, 8'd5, 8'd4};
                    6: canonical_ac_meta = {16'h0038, 8'd9, 8'd4};
                    7: canonical_ac_meta = {16'h0078, 8'd13, 8'd3};
                    8: canonical_ac_meta = {16'h00F6, 8'd16, 8'd4};
                    9: canonical_ac_meta = {16'h01F4, 8'd20, 8'd7};
                    10: canonical_ac_meta = {16'h03F6, 8'd27, 8'd5};
                    11: canonical_ac_meta = {16'h07F6, 8'd32, 8'd4};
                    12: canonical_ac_meta = {16'h0FF4, 8'd36, 8'd4};
                    14: canonical_ac_meta = {16'h3FE0, 8'd40, 8'd1};
                    15: canonical_ac_meta = {16'h7FC2, 8'd41, 8'd2};
                    16: canonical_ac_meta = {16'hFF88, 8'd43, 8'd119};
                    default: canonical_ac_meta = 32'd0;
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
            if (raw_value[size - 1'b1])
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
    always_comb begin
        next_huffman_code = {1'b0, huffman_code} << 1;
        next_huffman_code[0] = input_bit;
        next_huffman_length = huffman_length + 1'b1;
        huffman_meta = canonical_ac_meta(table_id, next_huffman_length);
        huffman_offset = next_huffman_code - {1'b0, huffman_meta[31:16]};
        huffman_match = (huffman_meta[7:0] != 0)
                     && (next_huffman_code >= {1'b0, huffman_meta[31:16]})
                     && (huffman_offset < {9'd0, huffman_meta[7:0]});
    end

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
            bit_position <= 3'd7;
            byte_valid <= 1'b0;
            byte_stream_last <= 1'b0;
            stream_end_seen <= 1'b0;
            huffman_code <= 16'd0;
            huffman_length <= 5'd0;
            ac_rom_address <= 9'd0;
            segment_position <= 6'd0;
            coefficient_target <= 6'd0;
            amplitude_size <= 4'd0;
            amplitude_count <= 4'd0;
            amplitude_bits <= 10'd0;
            coefficient_value <= 12'sd0;
            event_ctu_index <= 7'd0;
            event_block_index <= 3'd0;
            completed_stripe_count <= 32'd0;
            rejected_stripe_count <= 32'd0;
            syntax_error_count <= 32'd0;
        end else begin
            if (record_valid && record_ready) begin
                current_record_active <= 1'b1;
                current_bytes_left <= payload_length;
                current_record_final <=
                    (fragment_index + 1'b1 == fragment_count);
                current_record_accept <= 1'b0;
                if ((fragment_count == 0) || (fragment_index >= fragment_count)
                    || (payload_length == 0) || (stripe_id >= 45)
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
                    event_ctu_index <= 7'd0;
                    event_block_index <= 3'd0;
                    segment_position <= 6'd0;
                    state <= S_BLOCK_START;
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
                    bit_position <= 3'd7;
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
                bit_position <= bit_position - 1'b1;
                if (input_bit_is_last)
                    stream_end_seen <= 1'b1;
                if (state == S_PRESENCE) begin
                    state <= input_bit ? S_AC_HUFF : S_BLOCK_END;
                    huffman_code <= 16'd0;
                    huffman_length <= 5'd0;
                end else if (state == S_AC_HUFF) begin
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
                end else if (state == S_AC_AMPLITUDE) begin
                    amplitude_bits <= {amplitude_bits[8:0], input_bit};
                    if (amplitude_count + 1'b1 == amplitude_size) begin
                        coefficient_value <= amplitude_value(
                            {amplitude_bits, input_bit}, amplitude_size
                        );
                        segment_position <= coefficient_target + 1'b1;
                        state <= S_COEFFICIENT;
                    end else begin
                        amplitude_count <= amplitude_count + 1'b1;
                    end
                end
            end

            if (event_fire && (state == S_BLOCK_START)) begin
                segment_position <= 6'd0;
                huffman_code <= 16'd0;
                huffman_length <= 5'd0;
                state <= table_id ? S_AC_HUFF : S_PRESENCE;
            end
            if (state == S_AC_ROM_WAIT)
                state <= S_AC_SYMBOL;

            if (state == S_AC_SYMBOL) begin
                if (ac_rom_data == 8'h00) begin
                    state <= S_BLOCK_END;
                end else if (ac_rom_data == 8'hF0) begin
                    if (segment_position + 6'd16 > segment_length) begin
                        state <= S_ERROR;
                        stripe_active <= 1'b0;
                        syntax_error_count <= syntax_error_count + 1'b1;
                        rejected_stripe_count <= rejected_stripe_count + 1'b1;
                    end else begin
                        segment_position <= segment_position + 6'd16;
                        state <= (segment_position + 6'd16 == segment_length)
                               ? S_BLOCK_END : S_AC_HUFF;
                    end
                end else if ((ac_rom_data[3:0] == 0)
                             || (segment_position + {2'd0, ac_rom_data[7:4]}
                                 >= segment_length)) begin
                    state <= S_ERROR;
                    stripe_active <= 1'b0;
                    syntax_error_count <= syntax_error_count + 1'b1;
                    rejected_stripe_count <= rejected_stripe_count + 1'b1;
                end else begin
                    coefficient_target <=
                        segment_position + {2'd0, ac_rom_data[7:4]};
                    amplitude_size <= ac_rom_data[3:0];
                    amplitude_bits <= 10'd0;
                    amplitude_count <= 4'd0;
                    state <= S_AC_AMPLITUDE;
                end
            end

            if (event_fire && (state == S_COEFFICIENT)) begin
                state <= (segment_position == segment_length)
                       ? S_BLOCK_END : S_AC_HUFF;
                huffman_code <= 16'd0;
                huffman_length <= 5'd0;
            end

            if (event_fire && (state == S_BLOCK_END)) begin
                if ((event_block_index == 3'd5)
                    && (event_ctu_index == 7'(CTU_COUNT - 1))) begin
                    if (stream_end_seen) begin
                        completed_stripe_count <=
                            completed_stripe_count + 1'b1;
                    end else begin
                        syntax_error_count <= syntax_error_count + 1'b1;
                        rejected_stripe_count <= rejected_stripe_count + 1'b1;
                    end
                    stripe_active <= 1'b0;
                    state <= S_IDLE;
                end else begin
                    if (event_block_index == 3'd5) begin
                        event_ctu_index <= event_ctu_index + 1'b1;
                        event_block_index <= 3'd0;
                    end else begin
                        event_block_index <= event_block_index + 1'b1;
                    end
                    state <= S_BLOCK_START;
                end
            end

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
