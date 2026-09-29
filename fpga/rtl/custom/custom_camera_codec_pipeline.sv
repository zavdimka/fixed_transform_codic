module custom_camera_codec_pipeline (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         configured_quality24,

    input  logic         stripe_valid,
    output logic         stripe_take,
    input  logic [15:0]  stripe_frame_id,
    input  logic [5:0]   stripe_index,
    output logic [6:0]   read_ctu,
    output logic         read_ctu_start,
    input  logic         row_valid,
    output logic         row_ready,
    input  logic [5:0]   row_index,
    input  logic [127:0] row_data,
    output logic         stripe_release,

    output logic         m_valid,
    input  logic         m_ready,
    output logic         m_layer,
    output logic [7:0]   m_byte,
    output logic         packet_commit,
    input  logic         packet_commit_ready,
    output logic [15:0]  packet_frame_id,
    output logic [5:0]   packet_stripe_index,
    output logic [7:0]   packet_quality,
    output logic [16:0]  packet_base_bits,
    output logic [16:0]  packet_enhancement_bits,

    output logic         busy,
    output logic         fatal_error,
    output logic         coefficient_saturated,
    output logic [6:0]   ctu_index,
    output logic [3:0]   debug_state,
    output logic [6:0]   debug_completed_ctus,
    output logic [7:0]   debug_handshake
);
    typedef enum logic [3:0] {
        WAIT_STRIPE, START_STRIPE, START_CTU, LOAD_CTU,
        WAIT_CTU, WAIT_DRAIN, FINISH_STRIPE, WAIT_FINISH, COMMIT_PACKET
    } state_t;
    state_t state;
    logic [6:0] completed_ctus;

    logic stripe_start_ready, stripe_finish_ready, stripe_finish_done;
    logic ctu_start_ready, codec_row_ready;
    logic frontend_done, ctu_done, codec_busy;
    logic [127:0] left_y, next_left_y;
    logic [63:0] left_cb, left_cr, next_left_cb, next_left_cr;
    logic [31:0] unused_dc_satd, unused_horizontal_satd;
    logic [16:0] codec_base_bits, codec_enhancement_bits;
    logic [12:0] unused_base_bytes, unused_enhancement_bytes;
    logic active_quality24;

    assign stripe_take = state == WAIT_STRIPE && stripe_valid;
    assign read_ctu = ctu_index;
    assign read_ctu_start = state == START_CTU && ctu_start_ready;
    assign row_ready = state == LOAD_CTU && codec_row_ready;
    assign stripe_release = state == COMMIT_PACKET && packet_commit_ready;
    assign packet_commit = stripe_release;
    assign busy = state != WAIT_STRIPE || codec_busy;

    custom_pixel_ctu_entropy_writer36 codec (
        .clk(clk), .rst_n(rst_n),
        .stripe_start_valid(state == START_STRIPE),
        .stripe_start_ready(stripe_start_ready),
        .stripe_finish_valid(state == FINISH_STRIPE),
        .stripe_finish_ready(stripe_finish_ready),
        .stripe_finish_done(stripe_finish_done),
        .quality24(active_quality24),
        .base_limit_bits(17'd16384),
        .enhancement_limit_bits(17'd12288),
        .base_reserved_bits(17'd12000),
        .enhancement_reserved_bits(17'd1920),
        .ctu_start_valid(state == START_CTU),
        .ctu_start_ready(ctu_start_ready),
        // The decoder only has the reconstructed left CTU. Feeding the
        // encoder the original camera edge creates an open-loop predictor:
        // quantization error then accumulates across the stripe. Until a
        // closed-loop reconstructed edge is available, keep every CTU
        // independently decodable from the fixed DC predictor.
        .ctu_has_left(1'b0),
        .ctu_left_y(left_y), .ctu_left_cb(left_cb), .ctu_left_cr(left_cr),
        .s_valid(state == LOAD_CTU && row_valid),
        .s_ready(codec_row_ready), .s_row(row_data),
        .m_valid(m_valid), .m_ready(m_ready), .m_layer(m_layer),
        .m_byte(m_byte),
        .frontend_done(frontend_done), .ctu_done(ctu_done),
        .busy(codec_busy), .fatal_error(fatal_error),
        .coefficient_saturated(coefficient_saturated),
        .dc_satd(unused_dc_satd),
        .horizontal_satd(unused_horizontal_satd),
        .base_used_bits(codec_base_bits),
        .enhancement_used_bits(codec_enhancement_bits),
        .base_byte_count(unused_base_bytes),
        .enhancement_byte_count(unused_enhancement_bytes)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= WAIT_STRIPE;
            ctu_index <= 7'd0;
            completed_ctus <= 7'd0;
            left_y <= '0;
            left_cb <= '0;
            left_cr <= '0;
            next_left_y <= '0;
            next_left_cb <= '0;
            next_left_cr <= '0;
            packet_frame_id <= 16'd0;
            packet_stripe_index <= 6'd0;
            packet_quality <= 8'd24;
            packet_base_bits <= 17'd0;
            packet_enhancement_bits <= 17'd0;
            active_quality24 <= 1'b1;
        end else begin
            case (state)
                WAIT_STRIPE: begin
                    if (stripe_valid) begin
                        packet_frame_id <= stripe_frame_id;
                        packet_stripe_index <= stripe_index;
                        active_quality24 <= configured_quality24;
                        packet_quality <= configured_quality24 ? 8'd24 : 8'd20;
                        state <= START_STRIPE;
                    end
                end
                START_STRIPE: begin
                    if (stripe_start_ready) begin
                        ctu_index <= 7'd0;
                        completed_ctus <= 7'd0;
                        left_y <= '0;
                        left_cb <= '0;
                        left_cr <= '0;
                        state <= START_CTU;
                    end
                end
                START_CTU: begin
                    if (ctu_start_ready) begin
                        next_left_y <= '0;
                        next_left_cb <= '0;
                        next_left_cr <= '0;
                        state <= LOAD_CTU;
                    end
                end
                LOAD_CTU: begin
                    if (row_valid && codec_row_ready) begin
                        if (row_index < 16)
                            next_left_y[row_index * 8 +: 8]
                                <= row_data[127:120];
                        else if (row_index < 24)
                            next_left_cb[(row_index - 16) * 8 +: 8]
                                <= row_data[63:56];
                        else
                            next_left_cr[(row_index - 24) * 8 +: 8]
                                <= row_data[63:56];
                        if (row_index == 31) begin
                            left_y <= next_left_y;
                            left_cb <= next_left_cb;
                            left_cr <= {row_data[63:56], next_left_cr[55:0]};
                            state <= WAIT_CTU;
                        end
                    end
                end
                // The pixel frontend becomes idle after all three residual
                // pairs have entered the transform queue.  The entropy side
                // may still be draining this CTU, so start reading the next
                // one here instead of serializing on ctu_done.
                WAIT_CTU: begin
                    if (frontend_done) begin
                        if (ctu_index == 79)
                            state <= WAIT_DRAIN;
                        else begin
                            ctu_index <= ctu_index + 1'b1;
                            state <= START_CTU;
                        end
                    end
                end
                WAIT_DRAIN: begin
                    if (completed_ctus == 7'd80
                        || (ctu_done && completed_ctus == 7'd79))
                        state <= FINISH_STRIPE;
                end
                FINISH_STRIPE: begin
                    if (stripe_finish_ready)
                        state <= WAIT_FINISH;
                end
                WAIT_FINISH: begin
                    if (stripe_finish_done) begin
                        packet_base_bits <= codec_base_bits;
                        packet_enhancement_bits <= codec_enhancement_bits;
                        state <= COMMIT_PACKET;
                    end
                end
                COMMIT_PACKET: begin
                    if (packet_commit_ready)
                        state <= WAIT_STRIPE;
                end
                default: state <= WAIT_STRIPE;
            endcase

            if (ctu_done && completed_ctus < 7'd80)
                completed_ctus <= completed_ctus + 1'b1;
        end
    end

    assign debug_state = state;
    assign debug_completed_ctus = completed_ctus;
    assign debug_handshake = {
        frontend_done, ctu_done, ctu_start_ready, codec_row_ready,
        row_valid, read_ctu_start, packet_commit_ready, m_ready
    };

    logic unused_status;
    assign unused_status = frontend_done ^ unused_dc_satd[0]
                         ^ unused_horizontal_satd[0] ^ unused_base_bytes[0]
                         ^ unused_enhancement_bytes[0];
endmodule
