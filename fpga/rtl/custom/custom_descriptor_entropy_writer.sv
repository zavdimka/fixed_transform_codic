module custom_descriptor_entropy_writer #(
    parameter integer COUNT_WIDTH = 17,
    parameter integer TOKEN_WIDTH = 32,
    parameter integer BYTE_COUNT_WIDTH = 13,
    parameter integer FIFO_DEPTH = 4,
    parameter integer FIFO_LEVEL_WIDTH = $clog2(FIFO_DEPTH + 1)
) (
    input  logic                          clk,
    input  logic                          rst_n,

    input  logic                          start_valid,
    output logic                          start_ready,
    input  logic [COUNT_WIDTH-1:0]        base_limit_bits,
    input  logic [COUNT_WIDTH-1:0]        enhancement_limit_bits,
    input  logic [COUNT_WIDTH-1:0]        base_reserved_bits,
    input  logic [COUNT_WIDTH-1:0]        enhancement_reserved_bits,
    input  logic                          finish_valid,
    output logic                          finish_ready,
    output logic                          finish_done,

    input  logic                          prefix_valid,
    output logic                          prefix_ready,
    input  logic [1:0]                    prefix_mode,

    input  logic                          s_valid,
    output logic                          s_ready,
    input  logic [1:0]                    s_op_type,
    input  logic                          s_layer,
    input  logic                          s_mandatory,
    input  logic [5:0]                    s_reserve_release,
    input  logic                          s_table_class,
    input  logic                          s_table_id,
    input  logic [7:0]                    s_symbol,
    input  logic [10:0]                   s_amplitude,
    input  logic [3:0]                    s_amplitude_length,
    input  logic                          s_raw_value,
    input  logic [1:0]                    s_raw_length,
    input  logic                          s_eob_required,
    input  logic                          source_block_done,
    input  logic                          source_busy,
    input  logic                          source_error,
    input  logic                          source_saturated,
    output logic                          source_window_open,

    output logic                          m_valid,
    input  logic                          m_ready,
    output logic                          m_layer,
    output logic [7:0]                    m_byte,
    output logic                          drop_pulse,
    output logic                          drop_layer,
    output logic                          fatal_error,
    output logic                          busy,
    output logic [COUNT_WIDTH-1:0]        base_used_bits,
    output logic [COUNT_WIDTH-1:0]        enhancement_used_bits,
    output logic [BYTE_COUNT_WIDTH-1:0]   base_byte_count,
    output logic [BYTE_COUNT_WIDTH-1:0]   enhancement_byte_count,
    output logic                          coefficient_saturated,
    output logic [FIFO_LEVEL_WIDTH-1:0]   token_fifo_level
);
    logic writer_start_ready, writer_finish_ready, writer_busy;
    logic token_m_valid, token_m_ready, token_m_layer, token_m_mandatory;
    logic [TOKEN_WIDTH-1:0] token_m_bits;
    logic [5:0] token_m_length;
    logic [COUNT_WIDTH-1:0] token_m_reserve_release;
    logic token_input_error, token_busy, syntax_s_ready;
    logic writer_fatal_error, source_error_latched;
    logic start_fire, prefix_fire, prefix_token_fire;
    logic prefix_required, prefix_pending, prefix_bit_index;
    logic [1:0] active_prefix_mode;
    logic [2:0] completed_block_count;
    logic finish_boundary_valid;

    assign start_ready = writer_start_ready && !source_busy && !token_busy;
    assign start_fire = start_valid && start_ready;
    assign prefix_ready = writer_busy && !finish_valid && prefix_required
                        && !prefix_pending && !source_busy;
    assign prefix_fire = prefix_valid && prefix_ready;
    assign source_window_open = writer_busy && !finish_valid
                              && !prefix_required && !prefix_pending;
    assign s_ready = source_window_open && syntax_s_ready;
    assign prefix_token_fire = prefix_pending && syntax_s_ready;
    assign finish_boundary_valid = prefix_required && !prefix_pending
                                 && (completed_block_count == 0);
    assign finish_ready = writer_finish_ready && !source_busy && !token_busy
                        && finish_boundary_valid;
    assign busy = writer_busy || source_busy || token_busy || prefix_pending
                || (token_fifo_level != 0);
    assign fatal_error = source_error || source_error_latched
                       || token_input_error || writer_fatal_error;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            source_error_latched <= 1'b0;
            coefficient_saturated <= 1'b0;
            prefix_required <= 1'b0;
            prefix_pending <= 1'b0;
            prefix_bit_index <= 1'b0;
            active_prefix_mode <= '0;
            completed_block_count <= '0;
        end else begin
            if (start_fire) begin
                source_error_latched <= 1'b0;
                coefficient_saturated <= 1'b0;
                prefix_required <= 1'b1;
                prefix_pending <= 1'b0;
                prefix_bit_index <= 1'b0;
                active_prefix_mode <= '0;
                completed_block_count <= '0;
            end else begin
                if (source_error)
                    source_error_latched <= 1'b1;
                if (source_saturated)
                    coefficient_saturated <= 1'b1;

                if (prefix_fire) begin
                    prefix_pending <= 1'b1;
                    prefix_bit_index <= 1'b0;
                    active_prefix_mode <= prefix_mode;
                end
                if (prefix_token_fire) begin
                    if (!prefix_bit_index) begin
                        prefix_bit_index <= 1'b1;
                    end else begin
                        prefix_pending <= 1'b0;
                        prefix_required <= 1'b0;
                    end
                end

                if (source_block_done) begin
                    if (prefix_required || prefix_pending) begin
                        source_error_latched <= 1'b1;
                    end else if (completed_block_count == 3'd5) begin
                        completed_block_count <= '0;
                        prefix_required <= 1'b1;
                    end else begin
                        completed_block_count <= completed_block_count + 1'b1;
                    end
                end
            end
        end
    end

    custom_syntax_token_buffer #(
        .TOKEN_WIDTH(TOKEN_WIDTH), .COUNT_WIDTH(COUNT_WIDTH),
        .FIFO_DEPTH(FIFO_DEPTH)
    ) syntax_tokens (
        .clk(clk), .rst_n(rst_n), .clear(start_fire),
        .s_valid(prefix_pending || (s_valid && source_window_open)),
        .s_ready(syntax_s_ready),
        .s_op_type(prefix_pending ? 2'd0 : s_op_type),
        .s_layer(prefix_pending ? 1'b0 : s_layer),
        .s_mandatory(prefix_pending ? 1'b1 : s_mandatory),
        .s_reserve_release(prefix_pending ? 6'd1 : s_reserve_release),
        .s_table_class(prefix_pending ? 1'b0 : s_table_class),
        .s_table_id(prefix_pending ? 1'b0 : s_table_id),
        .s_symbol(prefix_pending ? 8'd0 : s_symbol),
        .s_amplitude(prefix_pending ? 11'd0 : s_amplitude),
        .s_amplitude_length(prefix_pending ? 4'd0 : s_amplitude_length),
        .s_raw_value(prefix_pending
                     ? (prefix_bit_index
                        ? active_prefix_mode[0] : active_prefix_mode[1])
                     : s_raw_value),
        .s_raw_length(prefix_pending ? 2'd1 : s_raw_length),
        .s_eob_required(prefix_pending ? 1'b0 : s_eob_required),
        .m_valid(token_m_valid), .m_ready(token_m_ready),
        .m_layer(token_m_layer), .m_bits(token_m_bits),
        .m_length(token_m_length), .m_mandatory(token_m_mandatory),
        .m_reserve_release(token_m_reserve_release),
        .input_error(token_input_error), .busy(token_busy),
        .fifo_level(token_fifo_level)
    );

    custom_bounded_byte_writer #(
        .COUNT_WIDTH(COUNT_WIDTH), .TOKEN_WIDTH(TOKEN_WIDTH),
        .BYTE_COUNT_WIDTH(BYTE_COUNT_WIDTH)
    ) writer (
        .clk(clk), .rst_n(rst_n),
        .start_valid(start_fire), .start_ready(writer_start_ready),
        .base_limit_bits(base_limit_bits),
        .enhancement_limit_bits(enhancement_limit_bits),
        .base_reserved_bits(base_reserved_bits),
        .enhancement_reserved_bits(enhancement_reserved_bits),
        .finish_valid(finish_valid && !source_busy && !token_busy
                      && finish_boundary_valid),
        .finish_ready(writer_finish_ready), .finish_done(finish_done),
        .s_valid(token_m_valid), .s_ready(token_m_ready),
        .s_layer(token_m_layer), .s_bits(token_m_bits),
        .s_length(token_m_length), .s_mandatory(token_m_mandatory),
        .s_reserve_release(token_m_reserve_release),
        .m_valid(m_valid), .m_ready(m_ready), .m_layer(m_layer),
        .m_byte(m_byte), .drop_pulse(drop_pulse), .drop_layer(drop_layer),
        .fatal_error(writer_fatal_error), .busy(writer_busy),
        .base_used_bits(base_used_bits),
        .enhancement_used_bits(enhancement_used_bits),
        .base_byte_count(base_byte_count),
        .enhancement_byte_count(enhancement_byte_count)
    );
endmodule
