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
    output logic [7:0]   block_quality,
    output logic [15:0]  block_frame_id,
    output logic [7:0]   block_stripe_id,
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
    localparam logic [3:0] S_HUFF_EVAL    = 4'd12;
    localparam logic [3:0] S_AC_SYMBOL_APPLY = 4'd13;
    localparam logic [3:0] S_HUFF_DECIDE  = 4'd14;
    localparam logic [3:0] S_RECORD_CHECK = 4'd15;

    // Keep remote record admission off a shared state-register CE.
    (* syn_encoding = "onehot", syn_useenables = 0 *) logic [3:0] state;
    logic [3:0] state_next;
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
    logic record_check_invalid;
    logic record_check_first;
    logic record_check_continuation_valid;
    logic record_check_stripe_was_active;
    logic [3:0] record_check_resume_state;
    logic amplitude_write_pending, amplitude_write_is_ac;
    logic [7:0] record_check_fragment_count;
    logic [15:0] record_check_frame_id;
    logic [7:0] record_check_stripe_id;
    logic [7:0] record_check_quality;
    logic continuation_wait;

    logic [7:0] bit_byte;
    // Force this compact bit-buffer island onto D-input muxes. Mapping its
    // updates onto FF clock enables creates a shared high-fanout FSM cone.
    (* syn_useenables = 0 *) logic [3:0] bits_remaining;
    (* syn_useenables = 0 *) logic [2:0] bit_position;
    (* syn_useenables = 0 *) logic byte_valid;
    logic byte_stream_last;
    (* syn_useenables = 0 *) logic stream_end_seen;

    (* syn_useenables = 0 *) logic mode_first_bit;
    (* syn_useenables = 0 *) logic mode_bit_count;
    logic [15:0] huffman_code;
    logic [4:0] huffman_length;
    logic [31:0] huffman_meta;
    logic huffman_is_ac;
    logic [3:0] amplitude_size;
    (* syn_useenables = 0 *) logic [10:0] amplitude_bits;
    (* syn_useenables = 0 *) logic [3:0] amplitude_count;
    logic amplitude_shift_active;
    logic [2:0] ac_position;
    logic [2:0] ac_target;
    logic [8:0] ac_rom_address;
    logic [7:0] ac_rom_data;
    (* syn_preserve = 1 *) logic [7:0] ac_symbol_latched;
    logic signed [11:0] coefficients [0:5];

    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    logic [7:0] ac_symbol_order [0:511];
    initial $readmemh(`RECEIVER_VLC_AC_DECODE_FILE, ac_symbol_order);
    always_ff @(posedge clk)
        ac_rom_data <= ac_symbol_order[ac_rom_address];

    wire table_id = (block_index >= 3'd4);
    wire [2:0] segment_length = table_id ? 3'd2 : 3'd5;
    wire need_bit = (state == S_MODE) || (state == S_DC_HUFF)
                  || (state == S_AC_PREFIX) || (state == S_AC_HUFF)
                  || (((state == S_DC_AMPLITUDE)
                    || (state == S_AC_AMPLITUDE))
                    && !amplitude_write_pending);
    wire bit_available = byte_valid && (bits_remaining != 0);
    wire input_bit = bit_byte[bit_position];
    wire bit_fire = need_bit && bit_available;
    wire input_bit_is_last = byte_stream_last && (bits_remaining == 1);
    wire payload_fire = payload_valid && payload_ready;
    wire record_fire = record_valid && record_ready;
    wire payload_length_error = payload_fire
        && ((payload_last && (current_bytes_left != 1))
            || (!payload_last && (current_bytes_left == 1)));
    wire stream_exhausted = stream_end_seen && !byte_valid
                          && need_bit && !bit_fire;
    // Register the exact continuation boundary so state decoding is not in
    // the record_ready -> record_fire -> next-state feedback path.
    assign record_ready = !current_record_active
                       && (!stripe_active || continuation_wait);
    assign payload_ready = current_record_active
                         && (state != S_RECORD_CHECK)
                         && (!current_record_accept || !byte_valid);
    assign block_valid = (state == S_BLOCK_OUTPUT);
    assign block_plane = (block_index < 3'd4) ? 2'd0
                       : (block_index == 3'd4) ? 2'd1 : 2'd2;
    assign block_quality = active_quality;
    assign block_frame_id = active_frame_id;
    assign block_stripe_id = active_stripe_id;
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

    // Keep the state register behind one state-local mux. The former
    // sequence of independent state assignments synthesized as a nine-level
    // priority chain even though almost all conditions were mutually
    // exclusive state decodes.
    always_comb begin
        state_next = state;
        case (state)
            S_RECORD_CHECK: begin
                if (record_check_invalid)
                    state_next = record_check_stripe_was_active
                               ? S_ERROR : record_check_resume_state;
                else if (record_check_first)
                    state_next = S_MODE;
                else if (record_check_continuation_valid)
                    state_next = record_check_resume_state;
                else
                    state_next = S_ERROR;
            end
            S_MODE: if (bit_available && !record_fire && mode_bit_count)
                state_next = S_BLOCK_START;
            S_BLOCK_START: state_next = S_DC_HUFF;
            S_DC_HUFF: if (bit_available && !record_fire)
                state_next = S_HUFF_EVAL;
            S_DC_AMPLITUDE: if (amplitude_write_pending)
                state_next = table_id ? S_AC_HUFF : S_AC_PREFIX;
            S_AC_PREFIX: if (bit_available && !record_fire)
                state_next = input_bit ? S_AC_HUFF : S_BLOCK_OUTPUT;
            S_AC_HUFF: if (bit_available && !record_fire)
                state_next = S_HUFF_EVAL;
            S_AC_ROM_WAIT: state_next = S_AC_SYMBOL;
            S_AC_SYMBOL: state_next = S_AC_SYMBOL_APPLY;
            S_AC_AMPLITUDE: if (amplitude_write_pending)
                state_next = (ac_target + 1'b1 == segment_length)
                           ? S_BLOCK_OUTPUT : S_AC_HUFF;
            S_BLOCK_OUTPUT: if (block_ready) begin
                if ((block_index == 3'd5)
                    && (block_ctu_index == 7'(CTU_COUNT - 1)))
                    state_next = S_IDLE;
                else if (block_index == 3'd5)
                    state_next = S_MODE;
                else
                    state_next = S_BLOCK_START;
            end
            S_HUFF_EVAL: state_next = S_HUFF_DECIDE;
            S_HUFF_DECIDE: begin
                if (huffman_match_latched) begin
                    if (huffman_is_ac)
                        state_next = S_AC_ROM_WAIT;
                    else if ((huffman_meta[15:8]
                              + huffman_offset_latched[7:0]) == 0)
                        state_next = table_id ? S_AC_HUFF : S_AC_PREFIX;
                    else
                        state_next = S_DC_AMPLITUDE;
                end else if (huffman_length >= 5'd16)
                    state_next = S_ERROR;
                else
                    state_next = huffman_is_ac ? S_AC_HUFF : S_DC_HUFF;
            end
            S_AC_SYMBOL_APPLY: begin
                if (ac_symbol_latched == 8'h00)
                    state_next = S_BLOCK_OUTPUT;
                else if ((ac_symbol_latched == 8'hF0)
                         || (ac_symbol_latched[3:0] == 0)
                         || (ac_position + ac_symbol_latched[7:4]
                             >= {1'b0, segment_length}))
                    state_next = S_ERROR;
                else
                    state_next = S_AC_AMPLITUDE;
            end
            S_ERROR: if (!current_record_active)
                state_next = S_IDLE;
            default: state_next = S_IDLE;
        endcase

        // Protocol faults retain the original highest priority.
        if (record_fire)
            state_next = S_RECORD_CHECK;
        if (payload_length_error || stream_exhausted)
            state_next = S_ERROR;
        if ((state == S_ERROR) && !current_record_active)
            state_next = S_IDLE;
    end
    logic [16:0] next_huffman_code;
    logic [4:0] next_huffman_length;
    logic [16:0] huffman_offset;
    logic huffman_match;
    logic huffman_match_latched;
    logic [16:0] huffman_offset_latched;
    logic [3:0] decoded_dc_size_latched;
    wire [3:0] decoded_dc_size = huffman_meta[11:8]
                                 + huffman_offset[3:0];
    always_comb begin
        next_huffman_code = {1'b0, huffman_code} << 1;
        next_huffman_code[0] = input_bit;
        next_huffman_length = huffman_length + 1'b1;
        huffman_offset = {1'b0, huffman_code}
                       - {1'b0, huffman_meta[31:16]};
        huffman_match = (huffman_meta[7:0] != 0)
                     && ({1'b0, huffman_code}
                         >= {1'b0, huffman_meta[31:16]})
                     && (huffman_offset < {9'd0, huffman_meta[7:0]});
    end

    integer coefficient_index;

    // Keep bit-buffer update priority local instead of sharing one large
    // clock-enable network with all decoder error and record-control paths.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            bits_remaining <= 4'd0;
            bit_position <= 3'd7;
            byte_valid <= 1'b0;
            stream_end_seen <= 1'b0;
            mode_first_bit <= 1'b0;
            mode_bit_count <= 1'b0;
            continuation_wait <= 1'b0;
        end else begin
            if (!stripe_active || record_fire)
                continuation_wait <= 1'b0;
            else if (!current_record_active && need_bit && !byte_valid)
                continuation_wait <= 1'b1;
            // Capture every consumed bit, independent of the FSM state. The
            // next mode-bit edge observes the previous consumed bit through
            // normal nonblocking-assignment semantics. Using bit_fire alone
            // keeps the high-fanout state decode out of this register's CE.
            if (bit_fire)
                mode_first_bit <= input_bit;
            if ((state == S_RECORD_CHECK) && !record_check_invalid
                && record_check_first) begin
                stream_end_seen <= 1'b0;
                byte_valid <= 1'b0;
                mode_bit_count <= 1'b0;
            end

            if (payload_fire && current_record_accept) begin
                byte_valid <= 1'b1;
                bit_position <= 3'd7;
                bits_remaining <= (payload_last && current_record_final)
                                ? ({1'b0, record_flags[2:0]} + 1'b1)
                                : 4'd8;
            end

            if (bit_fire && !(record_valid && record_ready)) begin
                if (bits_remaining == 1)
                    byte_valid <= 1'b0;
                bits_remaining <= bits_remaining - 1'b1;
                bit_position <= bit_position - 1'b1;
                if (input_bit_is_last)
                    stream_end_seen <= 1'b1;

                if (state == S_MODE) begin
                    if (mode_bit_count)
                        mode_bit_count <= 1'b0;
                    else begin
                        mode_bit_count <= 1'b1;
                    end
                end
            end

            if ((state == S_BLOCK_OUTPUT) && block_ready
                && (block_index == 3'd5)
                && (block_ctu_index != 7'(CTU_COUNT - 1))) begin
                mode_bit_count <= 1'b0;
            end

            if (stream_end_seen && !byte_valid && need_bit && !bit_fire)
                stream_end_seen <= 1'b0;

            if ((state == S_ERROR) && !current_record_active) begin
                byte_valid <= 1'b0;
                stream_end_seen <= 1'b0;
            end
        end
    end

    // Keep amplitude shifting in a small registered island. The main FSM
    // starts one transfer, then only this local active bit and bit availability
    // control the shift/count registers.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            amplitude_bits <= 11'd0;
            amplitude_count <= 4'd0;
            amplitude_shift_active <= 1'b0;
        end else if (!stripe_active || (state == S_ERROR)) begin
            amplitude_shift_active <= 1'b0;
        end else if ((state == S_HUFF_DECIDE)
                     && huffman_match_latched && !huffman_is_ac) begin
            amplitude_bits <= 11'd0;
            amplitude_count <= 4'd0;
            amplitude_shift_active <= (decoded_dc_size_latched != 0);
        end else if ((state == S_AC_SYMBOL_APPLY)
                     && (ac_symbol_latched != 8'h00)
                     && (ac_symbol_latched != 8'hF0)
                     && (ac_symbol_latched[3:0] != 0)
                     && (ac_position + ac_symbol_latched[7:4]
                         < {1'b0, segment_length})) begin
            amplitude_bits <= 11'd0;
            amplitude_count <= 4'd0;
            amplitude_shift_active <= 1'b1;
        end else if (amplitude_shift_active && bit_available) begin
            amplitude_bits <= {amplitude_bits[9:0], input_bit};
            if (amplitude_count + 1'b1 == amplitude_size)
                amplitude_shift_active <= 1'b0;
            else
                amplitude_count <= amplitude_count + 1'b1;
        end
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
            record_check_invalid <= 1'b0;
            record_check_first <= 1'b0;
            record_check_continuation_valid <= 1'b0;
            record_check_stripe_was_active <= 1'b0;
            record_check_resume_state <= S_IDLE;
            record_check_fragment_count <= 8'd0;
            record_check_frame_id <= 16'd0;
            record_check_stripe_id <= 8'd0;
            record_check_quality <= 8'd0;
            bit_byte <= 8'd0;
            byte_stream_last <= 1'b0;
            huffman_code <= 16'd0;
            huffman_length <= 5'd0;
            huffman_meta <= 32'd0;
            huffman_is_ac <= 1'b0;
            huffman_match_latched <= 1'b0;
            huffman_offset_latched <= 17'd0;
            decoded_dc_size_latched <= 4'd0;
            amplitude_size <= 4'd0;
            amplitude_write_pending <= 1'b0;
            amplitude_write_is_ac <= 1'b0;
            ac_position <= 3'd0;
            ac_target <= 3'd0;
            ac_rom_address <= 9'd0;
            ac_symbol_latched <= 8'd0;
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
            state <= state_next;
            stripe_done <= 1'b0;

            if (record_valid && record_ready) begin
                current_record_active <= 1'b1;
                current_bytes_left <= payload_length;
                current_record_final <=
                    (fragment_index + 1'b1 == fragment_count);
                current_record_accept <= 1'b0;
                record_check_invalid <=
                    (fragment_count == 0)
                    || (fragment_index >= fragment_count)
                    || (payload_length == 0)
                    || ((fragment_index + 1'b1 != fragment_count)
                        && (record_flags != 0))
                    || ((fragment_index + 1'b1 == fragment_count)
                        && (record_flags[7:3] != 0));
                record_check_first <= (fragment_index == 0);
                record_check_continuation_valid <= stripe_active
                    && (display_frame_id == active_frame_id)
                    && (stripe_id == active_stripe_id)
                    && (quality == active_quality)
                    && (fragment_count == active_fragment_count)
                    && (fragment_index == expected_fragment_index);
                record_check_stripe_was_active <= stripe_active;
                record_check_resume_state <= state;
                record_check_fragment_count <= fragment_count;
                record_check_frame_id <= display_frame_id;
                record_check_stripe_id <= stripe_id;
                record_check_quality <= quality;
            end

            if (state == S_RECORD_CHECK) begin
                if (record_check_invalid) begin
                    if (record_check_stripe_was_active)
                        stripe_active <= 1'b0;
                    rejected_stripe_count <= rejected_stripe_count + 1'b1;
                end else if (record_check_first) begin
                    if (record_check_stripe_was_active)
                        rejected_stripe_count <= rejected_stripe_count + 1'b1;
                    stripe_active <= 1'b1;
                    current_record_accept <= 1'b1;
                    expected_fragment_index <= 8'd1;
                    active_fragment_count <= record_check_fragment_count;
                    active_frame_id <= record_check_frame_id;
                    active_stripe_id <= record_check_stripe_id;
                    active_quality <= record_check_quality;
                    block_ctu_index <= 7'd0;
                    block_index <= 3'd0;
                end else if (record_check_continuation_valid) begin
                    current_record_accept <= 1'b1;
                    expected_fragment_index <= expected_fragment_index + 1'b1;
                end else begin
                    stripe_active <= 1'b0;
                    rejected_stripe_count <= rejected_stripe_count + 1'b1;
                end
            end
            if (payload_fire) begin
                if (current_bytes_left != 0)
                    current_bytes_left <= current_bytes_left - 1'b1;
                if (current_record_accept) begin
                    bit_byte <= payload_data;
                    byte_stream_last <= payload_last && current_record_final;
                end

                if (payload_last) begin
                    current_record_active <= 1'b0;
                    current_record_accept <= 1'b0;
                    if (current_bytes_left != 1) begin
                        stripe_active <= 1'b0;
                        rejected_stripe_count <= rejected_stripe_count + 1'b1;
                    end
                end else if (current_bytes_left == 1) begin
                    current_record_accept <= 1'b0;
                    stripe_active <= 1'b0;
                    rejected_stripe_count <= rejected_stripe_count + 1'b1;
                end
            end

            // Metadata acceptance has priority over consuming a buffered bit.
            // Otherwise the old state's transition can overwrite S_RECORD_CHECK
            // on the same edge as a continuation record handshake.
            if (bit_fire && !(record_valid && record_ready)) begin

                case (state)
                    S_MODE: begin
                        if (mode_bit_count) begin
                            block_mode <= {mode_first_bit, input_bit};
                        end
                    end

                    S_DC_HUFF: begin
                        huffman_code <= next_huffman_code[15:0];
                        huffman_length <= next_huffman_length;
                        huffman_meta <= canonical_meta(
                            1'b0, table_id, next_huffman_length
                        );
                        huffman_is_ac <= 1'b0;
                    end

                    S_DC_AMPLITUDE: begin
                        if (amplitude_count + 1'b1 == amplitude_size) begin
                            amplitude_write_is_ac <= 1'b0;
                            amplitude_write_pending <= 1'b1;
                        end
                    end

                    S_AC_PREFIX: begin
                        huffman_code <= 16'd0;
                        huffman_length <= 5'd0;
                    end

                    S_AC_HUFF: begin
                        huffman_code <= next_huffman_code[15:0];
                        huffman_length <= next_huffman_length;
                        huffman_meta <= canonical_meta(
                            1'b1, table_id, next_huffman_length
                        );
                        huffman_is_ac <= 1'b1;
                    end

                    S_AC_AMPLITUDE: begin
                        if (amplitude_count + 1'b1 == amplitude_size) begin
                            amplitude_write_is_ac <= 1'b1;
                            amplitude_write_pending <= 1'b1;
                        end
                    end
                    default: begin end
                endcase
            end

            if (amplitude_write_pending) begin
                amplitude_write_pending <= 1'b0;
                huffman_code <= 16'd0;
                huffman_length <= 5'd0;
                if (amplitude_write_is_ac) begin
                    coefficients[ac_target + 1'b1] <= amplitude_value(
                        amplitude_bits, amplitude_size
                    );
                    ac_position <= ac_target + 1'b1;
                end else begin
                    coefficients[0] <= amplitude_value(
                        amplitude_bits, amplitude_size
                    );
                end
            end
            if (state == S_BLOCK_START) begin
                for (coefficient_index = 0; coefficient_index < 6;
                     coefficient_index = coefficient_index + 1)
                    coefficients[coefficient_index] <= 12'sd0;
                ac_position <= 3'd0;
                huffman_code <= 16'd0;
                huffman_length <= 5'd0;
            end

            // Canonical table lookup is registered when the bit is consumed.
            // The following cycle only performs the subtract/compare and
            // symbol dispatch, breaking the former 23-level state-to-code
            // feedback path without changing any decoded value.
            if (state == S_HUFF_EVAL) begin
                // Register the subtract/compare result before it fans out into
                // state, counters and coefficient clears.
                huffman_match_latched <= huffman_match;
                huffman_offset_latched <= huffman_offset;
                decoded_dc_size_latched <= decoded_dc_size;
            end

            if (state == S_HUFF_DECIDE) begin
                if (huffman_match_latched) begin
                    huffman_code <= 16'd0;
                    huffman_length <= 5'd0;
                    if (huffman_is_ac) begin
                        ac_rom_address <= {table_id,
                            huffman_meta[15:8]
                            + huffman_offset_latched[7:0]};
                    end else begin
                        amplitude_size <= decoded_dc_size_latched;
                        if ((huffman_meta[15:8]
                             + huffman_offset_latched[7:0]) == 0)
                            coefficients[0] <= 12'sd0;
                    end
                end else if (huffman_length >= 5'd16) begin
                    stripe_active <= 1'b0;
                    syntax_error_count <= syntax_error_count + 1'b1;
                    rejected_stripe_count <= rejected_stripe_count + 1'b1;
                end
            end

            if (state == S_AC_SYMBOL) begin
                // Force an explicit fabric boundary after the synchronous
                // symbol ROM. Error/state fanout is evaluated one cycle later.
                ac_symbol_latched <= ac_rom_data;
            end

            if (state == S_AC_SYMBOL_APPLY) begin
                if (ac_symbol_latched == 8'h00) begin
                end else if ((ac_symbol_latched == 8'hF0)
                             || (ac_symbol_latched[3:0] == 0)
                             || (ac_position + ac_symbol_latched[7:4]
                                 >= {1'b0, segment_length})) begin
                    stripe_active <= 1'b0;
                    syntax_error_count <= syntax_error_count + 1'b1;
                    rejected_stripe_count <= rejected_stripe_count + 1'b1;
                end else begin
                    ac_target <= ac_position + ac_symbol_latched[6:4];
                    amplitude_size <= ac_symbol_latched[3:0];
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
                end else if (block_index == 3'd5) begin
                    block_ctu_index <= block_ctu_index + 1'b1;
                    block_index <= 3'd0;
                end else begin
                    block_index <= block_index + 1'b1;
                end
            end

            // A final fragment that runs out before a complete stripe is a
            // syntax error. Waiting between non-final fragments is legal.
            if (stream_end_seen && !byte_valid && need_bit && !bit_fire) begin
                stripe_active <= 1'b0;
                syntax_error_count <= syntax_error_count + 1'b1;
                rejected_stripe_count <= rejected_stripe_count + 1'b1;
            end

            if ((state == S_ERROR) && !current_record_active) begin
            end
        end
    end
endmodule
