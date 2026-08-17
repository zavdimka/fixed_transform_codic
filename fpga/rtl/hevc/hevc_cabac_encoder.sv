module hevc_cabac_encoder (
    input  logic       clk,
    input  logic       rst_n,

    input  logic       cfg_valid,
    output logic       cfg_ready,
    input  logic [7:0] cfg_context_address,
    input  logic [5:0] cfg_state_index,
    input  logic       cfg_mps,

    input  logic       start_valid,
    output logic       start_ready,

    input  logic       s_valid,
    output logic       s_ready,
    input  logic [1:0] s_kind,
    input  logic       s_bin,
    input  logic [7:0] s_context_address,

    output logic       m_valid,
    input  logic       m_ready,
    output logic [7:0] m_byte,
    output logic       m_last,

    output logic       context_update_valid,
    output logic [7:0] context_update_address,
    output logic [5:0] context_update_state_index,
    output logic       context_update_mps,
    output logic       slice_done,
    output logic       protocol_error,
    output logic       busy
);
    localparam logic [1:0] KIND_REGULAR = 2'd0;
    localparam logic [1:0] KIND_BYPASS = 2'd1;
    localparam logic [1:0] KIND_TERMINATE = 2'd2;

    typedef enum logic [3:0] {
        IDLE,
        ACTIVE,
        CONTEXT_WAIT,
        STEP_SEND,
        CHECK_WRITE,
        EMIT_WRITE,
        FINISH_PREP,
        FINISH_LOW,
        FINISH_WORD,
        FINISH_EMIT,
        FINISH_PREFIX,
        FINISH_TAIL
    } state_t;
    state_t state;

    logic [31:0] low_register;
    logic [8:0] range_register;
    logic [5:0] bits_left;
    logic [7:0] buffered_byte;
    logic [23:0] num_buffered_bytes;

    logic [1:0] pending_kind;
    logic pending_bin;
    logic [7:0] pending_context_address;
    logic finishing;
    logic skid_valid;
    logic [1:0] skid_kind;
    logic skid_bin;
    logic [7:0] skid_context_address;
    logic resume_step_after_emit;
    logic [1:0] next_step_kind;
    logic next_step_bin;
    logic [7:0] next_step_context_address;

    logic [23:0] repeat_count;
    logic [7:0] repeat_byte;
    logic [7:0] tail_first_byte;
    logic [7:0] tail_second_byte;
    logic tail_two_bytes;

    logic context_read_enable;
    logic [5:0] context_read_state_index;
    logic context_read_mps;
    logic context_update_enable;
    logic context_forward_valid;
    logic [5:0] context_forward_state_index;
    logic context_forward_mps;
    logic [5:0] selected_context_state_index;
    logic selected_context_mps;
    logic [5:0] staged_context_state_index;
    logic staged_context_mps;

    logic step_s_valid;
    // The bin-step input ready is intentionally not part of result chaining:
    // a registered result may retire while the encoder captures the next bin.
    /* verilator lint_off UNUSEDSIGNAL */
    logic step_s_ready;
    /* verilator lint_on UNUSEDSIGNAL */
    logic step_m_valid;
    logic step_m_ready;
    logic [31:0] step_m_low;
    logic [8:0] step_m_range;
    logic [5:0] step_m_state_index;
    logic step_m_mps;
    logic [2:0] step_m_renorm_bits;

    logic [8:0] range_minus_two;
    logic [5:0] write_new_bits_left;
    logic [5:0] write_shift;
    logic [31:0] write_lead_full;
    logic [8:0] write_lead_byte;
    logic [31:0] write_low_mask;
    logic [5:0] step_bits_left;
    logic step_output_slot_ready;
    logic skid_accept;
    logic next_step_available;

    logic [5:0] finish_shift_register;
    logic [4:0] finish_bit_count_register;
    logic [4:0] finish_total_bits_register;
    logic [2:0] finish_padding_register;
    logic finish_carry_register;
    logic [31:0] finish_low_register;
    logic [31:0] finish_data_mask_register;
    logic [31:0] finish_word_register;
    logic finish_two_bytes_register;

    assign cfg_ready = (state == IDLE);
    assign start_ready = (state == IDLE) && !cfg_valid;
    assign s_ready =
        ((state == ACTIVE) &&
        ((s_kind != KIND_TERMINATE) || step_output_slot_ready)) ||
        ((state == STEP_SEND) && step_m_valid && !skid_valid &&
        ((s_kind == KIND_REGULAR) || (s_kind == KIND_BYPASS)));
    assign busy = (state != IDLE);
    assign skid_accept = (state == STEP_SEND) && s_valid && s_ready;

    assign context_read_enable =
        s_valid && s_ready && (s_kind == KIND_REGULAR);
    assign context_update_enable =
        (state == STEP_SEND) && step_m_valid && step_m_ready &&
        (pending_kind == KIND_REGULAR);

    assign step_s_valid = (state == STEP_SEND);
    // Keep ready independent of the arithmetic result.  Previously
    // step_emits_byte fed back from the renormalized low value into ready and
    // then into several register enables, creating a 30+ level control path.
    // Conservatively stall the whole CABAC step whenever the byte output slot
    // is occupied.  With an accepting sink this has identical throughput.
    assign step_m_ready = (state == STEP_SEND) && step_output_slot_ready;
    assign selected_context_state_index = context_forward_valid ?
        context_forward_state_index : context_read_state_index;
    assign selected_context_mps = context_forward_valid ?
        context_forward_mps : context_read_mps;

    assign range_minus_two = range_register - 9'd2;
    assign write_new_bits_left = bits_left + 6'd8;
    assign write_shift = 6'd24 - bits_left;
    assign write_lead_full = low_register >> write_shift;
    assign write_lead_byte = write_lead_full[8:0];
    assign write_low_mask = 32'hffffffff >> write_new_bits_left;
    assign step_bits_left = bits_left - {3'd0, step_m_renorm_bits};
    assign step_output_slot_ready = !m_valid || m_ready;
    assign next_step_available = skid_valid || skid_accept;
    assign next_step_kind = skid_valid ? skid_kind : s_kind;
    assign next_step_bin = skid_valid ? skid_bin : s_bin;
    assign next_step_context_address = skid_valid ?
        skid_context_address : s_context_address;

    hevc_cabac_context_ram context_ram (
        .clk(clk),
        .cfg_write_enable(cfg_valid && cfg_ready),
        .cfg_address(cfg_context_address),
        .cfg_state_index(cfg_state_index),
        .cfg_mps(cfg_mps),
        .update_enable(context_update_enable),
        .update_address(pending_context_address),
        .update_state_index(step_m_state_index),
        .update_mps(step_m_mps),
        .read_enable(context_read_enable),
        .read_address(s_context_address),
        .read_state_index(context_read_state_index),
        .read_mps(context_read_mps)
    );

    hevc_cabac_bin_step #(
        .OUTPUT_REGISTER(1'b0),
        .SPLIT_LPS(1'b1),
        .SPLIT_MPS(1'b1)
    ) bin_step (
        .clk(clk),
        .rst_n(rst_n),
        .s_valid(step_s_valid),
        .s_ready(step_s_ready),
        .s_bin(pending_bin),
        .s_bypass(pending_kind == KIND_BYPASS),
        .s_low(low_register),
        .s_range(range_register),
        .s_state_index(staged_context_state_index),
        .s_mps(staged_context_mps),
        .m_valid(step_m_valid),
        .m_ready(step_m_ready),
        .m_low(step_m_low),
        .m_range(step_m_range),
        .m_state_index(step_m_state_index),
        .m_mps(step_m_mps),
        .m_renorm_bits(step_m_renorm_bits)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            low_register <= 32'd0;
            range_register <= 9'd510;
            bits_left <= 6'd23;
            buffered_byte <= 8'hff;
            num_buffered_bytes <= 24'd0;
            pending_kind <= KIND_REGULAR;
            pending_bin <= 1'b0;
            pending_context_address <= 8'd0;
            context_forward_valid <= 1'b0;
            context_forward_state_index <= 6'd0;
            context_forward_mps <= 1'b0;
            staged_context_state_index <= 6'd0;
            staged_context_mps <= 1'b0;
            skid_valid <= 1'b0;
            skid_kind <= KIND_REGULAR;
            skid_bin <= 1'b0;
            skid_context_address <= 8'd0;
            resume_step_after_emit <= 1'b0;
            finishing <= 1'b0;
            repeat_count <= 24'd0;
            repeat_byte <= 8'd0;
            tail_first_byte <= 8'd0;
            tail_second_byte <= 8'd0;
            tail_two_bytes <= 1'b0;
            finish_shift_register <= 0;
            finish_bit_count_register <= 0;
            finish_total_bits_register <= 0;
            finish_padding_register <= 0;
            finish_carry_register <= 0;
            finish_low_register <= 0;
            finish_data_mask_register <= 0;
            finish_word_register <= 0;
            finish_two_bytes_register <= 0;
            m_valid <= 1'b0;
            m_byte <= 8'd0;
            m_last <= 1'b0;
            context_update_valid <= 1'b0;
            context_update_address <= 8'd0;
            context_update_state_index <= 6'd0;
            context_update_mps <= 1'b0;
            slice_done <= 1'b0;
            protocol_error <= 1'b0;
        end else begin
            context_update_valid <= 1'b0;
            slice_done <= 1'b0;
            if (skid_accept) begin
                skid_valid <= 1'b1;
                skid_kind <= s_kind;
                skid_bin <= s_bin;
                skid_context_address <= s_context_address;
            end
            if (((state == ACTIVE) || (state == STEP_SEND)) &&
                    m_valid && m_ready) begin
                m_valid <= 1'b0;
                m_last <= 1'b0;
            end

            case (state)
                IDLE: begin
                    m_valid <= 1'b0;
                    m_last <= 1'b0;
                    if (start_valid && start_ready) begin
                        low_register <= 32'd0;
                        range_register <= 9'd510;
                        bits_left <= 6'd23;
                        buffered_byte <= 8'hff;
                        num_buffered_bytes <= 24'd0;
                        context_forward_valid <= 1'b0;
                        skid_valid <= 1'b0;
                        resume_step_after_emit <= 1'b0;
                        finishing <= 1'b0;
                        protocol_error <= 1'b0;
                        state <= ACTIVE;
                    end
                end

                ACTIVE: begin
                    if (s_valid && s_ready) begin
                        pending_kind <= s_kind;
                        pending_bin <= s_bin;
                        pending_context_address <= s_context_address;
                        context_forward_valid <= 1'b0;
                        resume_step_after_emit <= 1'b0;
                        finishing <= 1'b0;
                        case (s_kind)
                            KIND_REGULAR, KIND_BYPASS: begin
                                state <= (s_kind == KIND_REGULAR) ?
                                    CONTEXT_WAIT : STEP_SEND;
                            end
                            KIND_TERMINATE: begin
                                range_register <= range_minus_two;
                                if (s_bin) begin
                                    low_register <=
                                        (low_register +
                                        {23'd0, range_minus_two}) << 7;
                                    range_register <= 9'd256;
                                    bits_left <= bits_left - 6'd7;
                                    finishing <= 1'b1;
                                end else if (range_minus_two < 9'd256) begin
                                    low_register <= low_register << 1;
                                    range_register <= range_minus_two << 1;
                                    bits_left <= bits_left - 1'b1;
                                end
                                state <= CHECK_WRITE;
                            end
                            default: begin
                                protocol_error <= 1'b1;
                            end
                        endcase
                    end
                end

                CONTEXT_WAIT: begin
                    // The EBR context output has a long clock-to-Q delay.
                    // Isolate it from the LPS lookup and range subtraction;
                    // bypass bins skip this context-only pipeline stage.
                    staged_context_state_index <=
                        selected_context_state_index;
                    staged_context_mps <= selected_context_mps;
                    state <= STEP_SEND;
                end

                STEP_SEND: begin
                    if (step_m_valid && step_m_ready) begin
                        if (next_step_available) begin
                            pending_kind <= next_step_kind;
                            pending_bin <= next_step_bin;
                            pending_context_address <=
                                next_step_context_address;
                            skid_valid <= 1'b0;
                            context_forward_valid <=
                                (pending_kind == KIND_REGULAR) &&
                                (next_step_kind == KIND_REGULAR) &&
                                (pending_context_address ==
                                next_step_context_address);
                            context_forward_state_index <=
                                step_m_state_index;
                            context_forward_mps <= step_m_mps;
                        end else begin
                            context_forward_valid <= 1'b0;
                        end
                        range_register <= step_m_range;
                        if (pending_kind == KIND_REGULAR) begin
                            context_update_valid <= 1'b1;
                            context_update_address <=
                                pending_context_address;
                            context_update_state_index <=
                                step_m_state_index;
                            context_update_mps <= step_m_mps;
                        end
                        if (step_bits_left < 6'd12) begin
                            // Break the CABAC arithmetic-to-byte-output path.
                            // writeOut is uncommon compared with bin steps, so
                            // pay one cycle only when the low register crosses
                            // the byte boundary. CHECK_WRITE now works solely
                            // from registered low/bits_left values.
                            low_register <= step_m_low;
                            bits_left <= step_bits_left;
                            resume_step_after_emit <= next_step_available;
                            state <= CHECK_WRITE;
                        end else begin
                            low_register <= step_m_low;
                            bits_left <= step_bits_left;
                            resume_step_after_emit <= 1'b0;
                            state <= next_step_available ?
                                ((next_step_kind == KIND_REGULAR) ?
                                CONTEXT_WAIT : STEP_SEND) : ACTIVE;
                        end
                    end
                end

                CHECK_WRITE: begin
                    if (|write_lead_full[31:9]) begin
                        protocol_error <= 1'b1;
                    end
                    if (bits_left < 6'd12) begin
                        bits_left <= write_new_bits_left;
                        low_register <= low_register & write_low_mask;
                        if (write_lead_byte == 9'h0ff) begin
                            num_buffered_bytes <=
                                num_buffered_bytes + 1'b1;
                            state <= finishing ?
                                FINISH_PREP :
                                (resume_step_after_emit ?
                                ((pending_kind == KIND_REGULAR) ?
                                CONTEXT_WAIT : STEP_SEND) : ACTIVE);
                            resume_step_after_emit <= 1'b0;
                        end else if (num_buffered_bytes != 0) begin
                            m_valid <= 1'b1;
                            m_byte <= buffered_byte +
                                {7'd0, write_lead_byte[8]};
                            m_last <= 1'b0;
                            repeat_byte <= write_lead_byte[8] ?
                                8'h00 : 8'hff;
                            repeat_count <= num_buffered_bytes - 1'b1;
                            buffered_byte <= write_lead_byte[7:0];
                            num_buffered_bytes <= 24'd1;
                            state <= EMIT_WRITE;
                        end else begin
                            buffered_byte <= write_lead_byte[7:0];
                            num_buffered_bytes <= 24'd1;
                            state <= finishing ?
                                FINISH_PREP :
                                (resume_step_after_emit ?
                                ((pending_kind == KIND_REGULAR) ?
                                CONTEXT_WAIT : STEP_SEND) : ACTIVE);
                            resume_step_after_emit <= 1'b0;
                        end
                    end else begin
                        state <= finishing ? FINISH_PREP :
                            (resume_step_after_emit ?
                            ((pending_kind == KIND_REGULAR) ?
                            CONTEXT_WAIT : STEP_SEND) : ACTIVE);
                        resume_step_after_emit <= 1'b0;
                    end
                end

                EMIT_WRITE: begin
                    if (m_valid && m_ready) begin
                        if (repeat_count != 0) begin
                            m_byte <= repeat_byte;
                            repeat_count <= repeat_count - 1'b1;
                        end else begin
                            m_valid <= 1'b0;
                            state <= finishing ? FINISH_PREP :
                                (resume_step_after_emit ?
                                ((pending_kind == KIND_REGULAR) ?
                                CONTEXT_WAIT : STEP_SEND) : ACTIVE);
                            resume_step_after_emit <= 1'b0;
                        end
                    end
                end

                FINISH_PREP: begin
                    finish_shift_register <= 6'd32 - bits_left;
                    finish_bit_count_register <=
                        5'd24 - bits_left[4:0];
                    finish_total_bits_register <=
                        (5'd24 - bits_left[4:0]) + 1'b1;
                    finish_padding_register <=
                        bits_left[2:0] - 3'd1;
                    state <= FINISH_LOW;
                end

                FINISH_LOW: begin
                    finish_carry_register <=
                        |(low_register >> finish_shift_register);
                    finish_low_register <=
                        |(low_register >> finish_shift_register) ?
                        low_register -
                        (32'd1 << finish_shift_register) :
                        low_register;
                    finish_data_mask_register <=
                        (32'd1 << finish_bit_count_register) - 1'b1;
                    finish_two_bytes_register <=
                        ({1'b0, finish_total_bits_register} +
                        {3'd0, finish_padding_register}) > 6'd8;
                    state <= FINISH_WORD;
                end

                FINISH_WORD: begin
                    finish_word_register <=
                        ((((finish_low_register >> 8) &
                        finish_data_mask_register) << 1) |
                        32'd1) << finish_padding_register;
                    state <= FINISH_EMIT;
                end

                FINISH_EMIT: begin
                    if (|finish_word_register[31:16]) begin
                        protocol_error <= 1'b1;
                    end
                    low_register <= finish_low_register;
                    tail_first_byte <= finish_two_bytes_register ?
                        finish_word_register[15:8] :
                        finish_word_register[7:0];
                    tail_second_byte <= finish_word_register[7:0];
                    tail_two_bytes <= finish_two_bytes_register;
                    repeat_count <= (num_buffered_bytes > 0) ?
                        num_buffered_bytes - 1'b1 : 24'd0;
                    m_valid <= 1'b1;
                    m_last <= 1'b0;
                    if (finish_carry_register) begin
                        m_byte <= buffered_byte + 1'b1;
                        repeat_byte <= 8'h00;
                        state <= FINISH_PREFIX;
                    end else if (num_buffered_bytes != 0) begin
                        m_byte <= buffered_byte;
                        repeat_byte <= 8'hff;
                        state <= FINISH_PREFIX;
                    end else begin
                        m_byte <= finish_two_bytes_register ?
                            finish_word_register[15:8] :
                            finish_word_register[7:0];
                        m_last <= !finish_two_bytes_register;
                        state <= FINISH_TAIL;
                    end
                end

                FINISH_PREFIX: begin
                    if (m_valid && m_ready) begin
                        if (repeat_count != 0) begin
                            m_byte <= repeat_byte;
                            repeat_count <= repeat_count - 1'b1;
                        end else begin
                            m_byte <= tail_first_byte;
                            m_last <= !tail_two_bytes;
                            state <= FINISH_TAIL;
                        end
                    end
                end

                default: begin
                    if (m_valid && m_ready) begin
                        if (tail_two_bytes) begin
                            m_byte <= tail_second_byte;
                            m_last <= 1'b1;
                            tail_two_bytes <= 1'b0;
                        end else begin
                            m_valid <= 1'b0;
                            m_last <= 1'b0;
                            slice_done <= 1'b1;
                            state <= IDLE;
                        end
                    end
                end
            endcase
        end
    end
endmodule
