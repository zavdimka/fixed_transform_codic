module tb_camera_codec_stream (
    input  logic       pixel_clk,
    input  logic       codec_clk,
    input  logic       link_clk,
    input  logic       pixel_rst_n,
    input  logic       codec_rst_n,
    input  logic       link_rst_n,
    input  logic       pixel_vsync,
    input  logic       pixel_href,
    input  logic [7:0] pixel_data,
    output logic       packet_commit,
    output logic       codec_busy,
    output logic       fatal_error,
    output logic [6:0] ctu_index,
    output logic [15:0] dropped_stripes,
    output logic       buffer_overflow,
    output logic       packet_overflow,
    output logic [31:0] packet_count,
    output logic [3:0] scheduler_state,
    output logic [2:0] frontend_state
);
    logic stripe_valid, stripe_take, stripe_release;
    logic [15:0] stripe_frame_id;
    logic [5:0] stripe_index;
    logic [6:0] read_ctu;
    logic read_ctu_start, row_ready, row_valid;
    logic [5:0] row_index;
    logic [127:0] row_data;
    logic m_valid, m_layer;
    logic [7:0] m_byte;
    logic [15:0] packet_frame_id;
    logic [5:0] packet_stripe_index;
    logic [7:0] packet_quality;
    logic [16:0] packet_base_bits, packet_enhancement_bits;
    logic coefficient_saturated;
    logic packet_ready, packet_commit_ready;
    logic packet_active, packet_layer, packet_start, packet_end;
    logic [3:0] packet_data;
    logic [15:0] packet_byte_length;

    camera_yuv422_stripe_buffer8way stripes (
        .pixel_clk(pixel_clk), .pixel_rst_n(pixel_rst_n),
        .pixel_vsync(pixel_vsync), .pixel_href(pixel_href),
        .pixel_data(pixel_data),
        .read_clk(codec_clk), .read_rst_n(codec_rst_n),
        .stripe_valid(stripe_valid), .stripe_take(stripe_take),
        .stripe_frame_id(stripe_frame_id), .stripe_index(stripe_index),
        .read_ctu(read_ctu), .read_ctu_start(read_ctu_start),
        .row_ready(row_ready), .row_valid(row_valid),
        .row_index(row_index), .row_data(row_data),
        .stripe_release(stripe_release), .overflow(buffer_overflow),
        .dropped_stripes(dropped_stripes)
    );

    custom_camera_codec_pipeline camera_codec (
        .clk(codec_clk), .rst_n(codec_rst_n),
        .configured_quality24(1'b1),
        .stripe_valid(stripe_valid), .stripe_take(stripe_take),
        .stripe_frame_id(stripe_frame_id), .stripe_index(stripe_index),
        .read_ctu(read_ctu), .read_ctu_start(read_ctu_start),
        .row_valid(row_valid), .row_ready(row_ready),
        .row_index(row_index), .row_data(row_data),
        .stripe_release(stripe_release),
        .m_valid(m_valid), .m_ready(packet_ready),
        .m_layer(m_layer), .m_byte(m_byte),
        .packet_commit(packet_commit),
        .packet_commit_ready(packet_commit_ready),
        .packet_frame_id(packet_frame_id),
        .packet_stripe_index(packet_stripe_index),
        .packet_quality(packet_quality),
        .packet_base_bits(packet_base_bits),
        .packet_enhancement_bits(packet_enhancement_bits),
        .busy(codec_busy), .fatal_error(fatal_error),
        .coefficient_saturated(coefficient_saturated),
        .ctu_index(ctu_index),
        .debug_state(), .debug_completed_ctus(), .debug_handshake()
    );

    link_record_packetizer #(
        .MAX_LAYER_BYTES(2048), .FRAGMENT_BYTES(1400),
        .WIRE_RECORD_BYTES(1420)
    ) packets (
        .write_clk(codec_clk), .write_rst_n(codec_rst_n),
        .s_valid(m_valid), .s_ready(packet_ready),
        .s_data(m_byte), .s_layer(m_layer),
        .s_commit(packet_commit), .s_commit_ready(packet_commit_ready),
        .s_frame_id(packet_frame_id),
        .s_stripe_index(packet_stripe_index),
        .s_quality(packet_quality),
        .s_base_bits(packet_base_bits),
        .s_enhancement_bits(packet_enhancement_bits),
        .write_overflow(packet_overflow),
        .read_clk(link_clk), .read_rst_n(link_rst_n),
        .read_enable(1'b1), .gap_cycles(16'd1024),
        .packet_active(packet_active), .packet_data(packet_data),
        .packet_layer(packet_layer), .packet_start(packet_start),
        .packet_end(packet_end),
        .packet_byte_length(packet_byte_length),
        .packet_count(packet_count)
    );

    assign scheduler_state = camera_codec.state;
    assign frontend_state = camera_codec.codec.frontend.state;

    logic unused_packet_outputs;
    assign unused_packet_outputs = packet_active ^ packet_layer
                                 ^ packet_start ^ packet_end
                                 ^ packet_data[0] ^ packet_byte_length[0];
endmodule
