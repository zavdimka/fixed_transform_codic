module custom_codec_synthesis_harness (
    input  logic       clk,
    input  logic       rst_n,
    input  logic [7:0] seed_data,
    input  logic [2:0] seed_control,
    input  logic [1:0] source_mode,

    output logic       m_valid,
    input  logic       m_ready,
    output logic       m_layer,
    output logic [7:0] m_byte,
    output logic       packet_commit,

    output logic       busy,
    output logic       fatal_error,
    output logic       coefficient_saturated,
    output logic       quality24,
    output logic [2:0] ctu_index
);
    typedef enum logic [2:0] {
        START_STRIPE, START_CTU, LOAD_CTU, WAIT_CTU,
        FINISH_STRIPE, WAIT_FINISH
    } state_t;
    state_t state;

    logic stripe_start_ready, stripe_finish_ready, stripe_finish_done;
    logic ctu_start_ready, s_ready;
    logic frontend_done, ctu_done, codec_busy;
    logic [5:0] row_index;
    logic [127:0] source_lfsr;
    logic [127:0] source_row;
    logic [127:0] left_y;
    logic [63:0] left_cb, left_cr;
    logic [127:0] next_left_y;
    logic [63:0] next_left_cb, next_left_cr;
    logic [31:0] unused_dc_satd, unused_horizontal_satd;
    logic [16:0] unused_base_bits, unused_enhancement_bits;
    logic [12:0] unused_base_bytes, unused_enhancement_bytes;

    wire lfsr_feedback = source_lfsr[127] ^ source_lfsr[125]
                       ^ source_lfsr[100] ^ source_lfsr[98];

    integer source_lane;
    logic [7:0] pattern_sample;
    always_comb begin
        source_row = source_lfsr;
        pattern_sample = 8'd0;
        if (source_mode != 0) begin
            source_row = 128'd0;
            for (source_lane = 0; source_lane < 16;
                 source_lane = source_lane + 1) begin
                if (row_index < 16) begin
                    if (source_mode == 1)
                        pattern_sample = 8'd16
                            + {ctu_index, 4'b0000}
                            + source_lane[7:0]
                            + {row_index[4:0], 2'b00};
                    else if (ctu_index[0] ^ row_index[3]
                             ^ source_lane[3])
                        pattern_sample = 8'd208;
                    else
                        pattern_sample = 8'd48;
                end else if (row_index < 24) begin
                    pattern_sample = (source_mode == 1)
                        ? 8'd96 : (ctu_index[0] ? 8'd176 : 8'd80);
                end else begin
                    pattern_sample = (source_mode == 1)
                        ? 8'd160 : (ctu_index[0] ? 8'd80 : 8'd176);
                end
                source_row[source_lane * 8 +: 8] = pattern_sample;
            end
        end
    end

    custom_pixel_ctu_entropy_writer36 codec (
        .clk(clk), .rst_n(rst_n),
        .stripe_start_valid(state == START_STRIPE),
        .stripe_start_ready(stripe_start_ready),
        .stripe_finish_valid(state == FINISH_STRIPE),
        .stripe_finish_ready(stripe_finish_ready),
        .stripe_finish_done(stripe_finish_done),
        .quality24(quality24),
        .base_limit_bits(17'd16384),
        .enhancement_limit_bits(17'd12288),
        .base_reserved_bits(17'd600),
        .enhancement_reserved_bits(17'd96),
        .ctu_start_valid(state == START_CTU),
        .ctu_start_ready(ctu_start_ready),
        .ctu_has_left(ctu_index != 0),
        .ctu_left_y(left_y), .ctu_left_cb(left_cb), .ctu_left_cr(left_cr),
        .s_valid(state == LOAD_CTU), .s_ready(s_ready), .s_row(source_row),
        .m_valid(m_valid), .m_ready(m_ready), .m_layer(m_layer),
        .m_byte(m_byte),
        .frontend_done(frontend_done), .ctu_done(ctu_done),
        .busy(codec_busy), .fatal_error(fatal_error),
        .coefficient_saturated(coefficient_saturated),
        .dc_satd(unused_dc_satd),
        .horizontal_satd(unused_horizontal_satd),
        .base_used_bits(unused_base_bits),
        .enhancement_used_bits(unused_enhancement_bits),
        .base_byte_count(unused_base_bytes),
        .enhancement_byte_count(unused_enhancement_bytes)
    );

    assign busy = state != START_STRIPE || codec_busy;
    assign packet_commit = stripe_finish_done;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= START_STRIPE;
            quality24 <= 1'b0;
            ctu_index <= '0;
            row_index <= '0;
            source_lfsr <= 128'h1;
            left_y <= '0;
            left_cb <= '0;
            left_cr <= '0;
            next_left_y <= '0;
            next_left_cb <= '0;
            next_left_cr <= '0;
        end else begin
            case (state)
                START_STRIPE: begin
                    if (stripe_start_ready) begin
                        ctu_index <= '0;
                        state <= START_CTU;
                    end
                end
                START_CTU: begin
                    if (ctu_start_ready) begin
                        row_index <= '0;
                        source_lfsr <= {
                            93'h12d5a6b79c3e1f0842a51bc,
                            seed_control, seed_data, ctu_index, 21'h15555
                        };
                        next_left_y <= '0;
                        next_left_cb <= '0;
                        next_left_cr <= '0;
                        state <= LOAD_CTU;
                    end
                end
                LOAD_CTU: begin
                    if (s_ready) begin
                        source_lfsr <= {source_lfsr[126:0], lfsr_feedback};
                        if (row_index < 16)
                            next_left_y[row_index * 8 +: 8]
                                <= source_row[127:120];
                        else if (row_index < 24)
                            next_left_cb[(row_index - 16) * 8 +: 8]
                                <= source_row[63:56];
                        else
                            next_left_cr[(row_index - 24) * 8 +: 8]
                                <= source_row[63:56];
                        if (row_index == 31) begin
                            left_y <= next_left_y;
                            left_cb <= next_left_cb;
                            left_cr <= {source_row[63:56],
                                        next_left_cr[55:0]};
                            state <= WAIT_CTU;
                        end else begin
                            row_index <= row_index + 1'b1;
                        end
                    end
                end
                WAIT_CTU: begin
                    if (ctu_done) begin
                        if (ctu_index == 3)
                            state <= FINISH_STRIPE;
                        else begin
                            ctu_index <= ctu_index + 1'b1;
                            state <= START_CTU;
                        end
                    end
                end
                FINISH_STRIPE: begin
                    if (stripe_finish_ready)
                        state <= WAIT_FINISH;
                end
                default: begin
                    if (stripe_finish_done) begin
                        quality24 <= ~quality24;
                        state <= START_STRIPE;
                    end
                end
            endcase
        end
    end

    logic unused_status;
    assign unused_status = frontend_done ^ unused_dc_satd[0]
                         ^ unused_horizontal_satd[0] ^ unused_base_bits[0]
                         ^ unused_enhancement_bits[0] ^ unused_base_bytes[0]
                         ^ unused_enhancement_bytes[0];
endmodule
