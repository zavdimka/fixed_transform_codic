module custom_fixed_entropy_writer #(
    parameter integer COUNT_WIDTH = 17,
    parameter integer TOKEN_WIDTH = 32,
    parameter integer BYTE_COUNT_WIDTH = 13
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

    input  logic                          s_valid,
    output logic                          s_ready,
    input  logic                          s_layer,
    input  logic                          s_mandatory,
    input  logic [COUNT_WIDTH-1:0]        s_reserve_release,
    input  logic                          s_table_class,
    input  logic                          s_table_id,
    input  logic [7:0]                    s_symbol,
    input  logic [10:0]                   s_amplitude,
    input  logic [3:0]                    s_amplitude_length,

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
    output logic [BYTE_COUNT_WIDTH-1:0]   enhancement_byte_count
);

    logic vlc_s_ready, vlc_m_valid, vlc_m_ready, vlc_input_error, vlc_busy;
    logic [TOKEN_WIDTH-1:0] vlc_m_bits;
    logic [5:0] vlc_m_length;
    logic buffered_layer, buffered_mandatory;
    logic [COUNT_WIDTH-1:0] buffered_reserve_release;
    logic stream_start_ready, stream_finish_ready, stream_busy;
    logic stream_fatal_error;
    logic input_fire;

    assign start_ready = stream_start_ready && vlc_s_ready;
    assign finish_ready = stream_finish_ready && !vlc_busy;
    assign s_ready = stream_busy && !finish_valid && vlc_s_ready;
    assign input_fire = s_valid && s_ready;
    assign busy = stream_busy;

    custom_vlc_encoder #(
        .TOKEN_WIDTH(TOKEN_WIDTH)
    ) vlc (
        .clk(clk),
        .rst_n(rst_n),
        .clear_error(start_valid && start_ready),
        .s_valid(s_valid && stream_busy && !finish_valid),
        .s_ready(vlc_s_ready),
        .s_table_class(s_table_class),
        .s_table_id(s_table_id),
        .s_symbol(s_symbol),
        .s_amplitude(s_amplitude),
        .s_amplitude_length(s_amplitude_length),
        .m_valid(vlc_m_valid),
        .m_ready(vlc_m_ready),
        .m_bits(vlc_m_bits),
        .m_length(vlc_m_length),
        .input_error(vlc_input_error),
        .busy(vlc_busy)
    );

    custom_bounded_byte_writer #(
        .COUNT_WIDTH(COUNT_WIDTH),
        .TOKEN_WIDTH(TOKEN_WIDTH),
        .BYTE_COUNT_WIDTH(BYTE_COUNT_WIDTH)
    ) stream (
        .clk(clk),
        .rst_n(rst_n),
        .start_valid(start_valid && vlc_s_ready),
        .start_ready(stream_start_ready),
        .base_limit_bits(base_limit_bits),
        .enhancement_limit_bits(enhancement_limit_bits),
        .base_reserved_bits(base_reserved_bits),
        .enhancement_reserved_bits(enhancement_reserved_bits),
        .finish_valid(finish_valid && !vlc_busy),
        .finish_ready(stream_finish_ready),
        .finish_done(finish_done),
        .s_valid(vlc_m_valid),
        .s_ready(vlc_m_ready),
        .s_layer(buffered_layer),
        .s_bits(vlc_m_bits),
        .s_length(vlc_m_length),
        .s_mandatory(buffered_mandatory),
        .s_reserve_release(buffered_reserve_release),
        .m_valid(m_valid),
        .m_ready(m_ready),
        .m_layer(m_layer),
        .m_byte(m_byte),
        .drop_pulse(drop_pulse),
        .drop_layer(drop_layer),
        .fatal_error(stream_fatal_error),
        .busy(stream_busy),
        .base_used_bits(base_used_bits),
        .enhancement_used_bits(enhancement_used_bits),
        .base_byte_count(base_byte_count),
        .enhancement_byte_count(enhancement_byte_count)
    );

    assign fatal_error = vlc_input_error || stream_fatal_error;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            buffered_layer <= 1'b0;
            buffered_mandatory <= 1'b0;
            buffered_reserve_release <= '0;
        end else if (input_fire) begin
            buffered_layer <= s_layer;
            buffered_mandatory <= s_mandatory;
            buffered_reserve_release <= s_reserve_release;
        end
    end

endmodule
