module custom_syntax_dispatcher #(
    parameter integer TOKEN_WIDTH = 32
) (
    input  logic                       clk,
    input  logic                       rst_n,
    input  logic                       clear_error,

    input  logic                       s_valid,
    output logic                       s_ready,
    input  logic [1:0]                 s_op_type,
    input  logic                       s_layer,
    input  logic                       s_mandatory,
    input  logic [5:0]                 s_reserve_release,
    input  logic                       s_table_class,
    input  logic                       s_table_id,
    input  logic [7:0]                 s_symbol,
    input  logic [10:0]                s_amplitude,
    input  logic [3:0]                 s_amplitude_length,
    input  logic                       s_raw_value,
    input  logic [1:0]                 s_raw_length,
    input  logic                       s_eob_required,

    output logic                       m_valid,
    input  logic                       m_ready,
    output logic                       m_layer,
    output logic [TOKEN_WIDTH-1:0]     m_bits,
    output logic [5:0]                 m_length,
    output logic                       m_mandatory,
    output logic [5:0]                 m_reserve_release,

    output logic                       input_error,
    output logic                       busy
);

    localparam logic [1:0] OP_RAW = 2'd0;
    localparam logic [1:0] OP_VLC = 2'd1;
    localparam logic [1:0] OP_SEGMENT_END = 2'd2;

    typedef enum logic {
        IDLE,
        WAIT_VLC
    } state_t;

    state_t state;
    logic operation_needs_vlc;
    logic output_slot_available;
    logic input_fire;
    logic protocol_error;

    logic vlc_s_valid, vlc_s_ready;
    logic vlc_m_valid, vlc_m_ready;
    logic [TOKEN_WIDTH-1:0] vlc_m_bits;
    logic [5:0] vlc_m_length;
    logic vlc_input_error, vlc_busy;
    logic vlc_table_class;
    logic [7:0] vlc_symbol;
    logic [10:0] vlc_amplitude;
    logic [3:0] vlc_amplitude_length;

    logic buffered_layer, buffered_mandatory;
    logic [5:0] buffered_reserve_release;

    always_comb begin
        operation_needs_vlc = (s_op_type == OP_VLC)
                           || ((s_op_type == OP_SEGMENT_END)
                               && s_eob_required);
        output_slot_available = !m_valid || m_ready;
        if (state != IDLE)
            s_ready = 1'b0;
        else if (operation_needs_vlc)
            s_ready = output_slot_available && vlc_s_ready;
        else
            s_ready = output_slot_available;
        input_fire = s_valid && s_ready;

        vlc_s_valid = s_valid && (state == IDLE)
                   && output_slot_available && operation_needs_vlc;
        vlc_table_class = (s_op_type == OP_SEGMENT_END)
                        ? 1'b1 : s_table_class;
        vlc_symbol = (s_op_type == OP_SEGMENT_END) ? 8'h00 : s_symbol;
        vlc_amplitude = (s_op_type == OP_SEGMENT_END) ? 0 : s_amplitude;
        vlc_amplitude_length = (s_op_type == OP_SEGMENT_END)
                             ? 0 : s_amplitude_length;
        vlc_m_ready = (state == WAIT_VLC) && !m_valid;

        input_error = protocol_error || vlc_input_error;
        busy = (state != IDLE) || m_valid || vlc_busy;
    end

    custom_vlc_encoder #(
        .TOKEN_WIDTH(TOKEN_WIDTH)
    ) vlc (
        .clk(clk),
        .rst_n(rst_n),
        .clear_error(clear_error),
        .s_valid(vlc_s_valid),
        .s_ready(vlc_s_ready),
        .s_table_class(vlc_table_class),
        .s_table_id(s_table_id),
        .s_symbol(vlc_symbol),
        .s_amplitude(vlc_amplitude),
        .s_amplitude_length(vlc_amplitude_length),
        .m_valid(vlc_m_valid),
        .m_ready(vlc_m_ready),
        .m_bits(vlc_m_bits),
        .m_length(vlc_m_length),
        .input_error(vlc_input_error),
        .busy(vlc_busy)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            m_valid <= 1'b0;
            m_layer <= 1'b0;
            m_bits <= '0;
            m_length <= 0;
            m_mandatory <= 1'b0;
            m_reserve_release <= 0;
            buffered_layer <= 1'b0;
            buffered_mandatory <= 1'b0;
            buffered_reserve_release <= 0;
            protocol_error <= 1'b0;
        end else begin
            if (clear_error)
                protocol_error <= 1'b0;
            if (m_valid && m_ready)
                m_valid <= 1'b0;

            if (input_fire) begin
                if (operation_needs_vlc) begin
                    buffered_layer <= s_layer;
                    buffered_mandatory <= s_mandatory;
                    buffered_reserve_release <= s_reserve_release;
                    state <= WAIT_VLC;
                end else if (s_op_type == OP_RAW) begin
                    if (s_raw_length == 1) begin
                        m_valid <= 1'b1;
                        m_layer <= s_layer;
                        m_bits <= {{(TOKEN_WIDTH-1){1'b0}}, s_raw_value}
                                << (TOKEN_WIDTH - 1);
                        m_length <= 1;
                        m_mandatory <= s_mandatory;
                        m_reserve_release <= s_reserve_release;
                    end else begin
                        protocol_error <= 1'b1;
                    end
                end else if (s_op_type == OP_SEGMENT_END) begin
                    m_valid <= 1'b1;
                    m_layer <= s_layer;
                    m_bits <= '0;
                    m_length <= 0;
                    m_mandatory <= s_mandatory;
                    m_reserve_release <= s_reserve_release;
                end else begin
                    protocol_error <= 1'b1;
                end
            end

            if (vlc_m_valid && vlc_m_ready) begin
                m_valid <= 1'b1;
                m_layer <= buffered_layer;
                m_bits <= vlc_m_bits;
                m_length <= vlc_m_length;
                m_mandatory <= buffered_mandatory;
                m_reserve_release <= buffered_reserve_release;
                state <= IDLE;
            end else if ((state == WAIT_VLC) && vlc_input_error && !vlc_busy) begin
                protocol_error <= 1'b1;
                state <= IDLE;
            end
        end
    end

endmodule
