module hevc_chroma_intra8 (
    input  logic              clk,
    input  logic              rst_n,

    input  logic              start_valid,
    output logic              start_ready,
    input  logic              luma_mode_dc,

    // Index 0 is top-left, 1..8 border the TU and 9 is top-right/bottom-left.
    input  logic              ref_valid,
    output logic              ref_ready,
    input  logic [7:0]        ref_top,
    input  logic [7:0]        ref_left,
    input  logic              ref_last,

    input  logic              s_valid,
    output logic              s_ready,
    input  logic [7:0]        s_pixel,

    output logic              m_valid,
    input  logic              m_ready,
    output logic [7:0]        m_prediction,
    output logic signed [8:0] m_residual,
    output logic              m_block_last,

    output logic              done,
    output logic              protocol_error,
    output logic              busy
);
    typedef enum logic [1:0] {
        IDLE,
        LOAD_REFERENCES,
        PROCESS_PIXELS,
        DRAIN_OUTPUT
    } state_t;

    state_t state;
    logic mode_dc;
    logic [7:0] top_samples [0:9];
    logic [7:0] left_samples [0:9];
    logic [3:0] reference_index;
    logic [2:0] pixel_x;
    logic [2:0] pixel_y;

    logic [11:0] reference_sum;
    logic [9:0] reference_pair;
    logic [12:0] dc_numerator;
    logic [7:0] dc_value;

    logic signed [11:0] vertical_accumulator [0:7];
    logic signed [11:0] horizontal_accumulator;
    logic signed [11:0] horizontal_start;
    logic signed [11:0] horizontal_next;
    logic signed [11:0] vertical_next;
    logic signed [12:0] planar_sum;
    logic [7:0] planar_prediction;
    logic [7:0] prediction;

    wire start_fire = start_valid && start_ready;
    wire reference_fire = ref_valid && ref_ready;
    wire input_fire = s_valid && s_ready;
    wire output_fire = m_valid && m_ready;

    assign start_ready = state == IDLE;
    assign ref_ready = state == LOAD_REFERENCES;
    assign s_ready = (state == PROCESS_PIXELS) && (!m_valid || m_ready);
    assign busy = state != IDLE;

    assign reference_pair = {2'd0, ref_top} + {2'd0, ref_left};
    assign dc_numerator = {1'b0, reference_sum} +
        {3'd0, reference_pair} + 13'd8;

    always_comb begin
        horizontal_start = $signed({1'b0,
            left_samples[{1'b0, pixel_y} + 4'd1], 3'b000}) + 12'sd8;
        horizontal_next = ((pixel_x == 0) ?
            horizontal_start : horizontal_accumulator) +
            $signed({4'd0, top_samples[9]}) -
            $signed({4'd0, left_samples[{1'b0, pixel_y} + 4'd1]});
        vertical_next = vertical_accumulator[pixel_x] +
            $signed({4'd0, left_samples[9]}) -
            $signed({4'd0, top_samples[{1'b0, pixel_x} + 4'd1]});
        planar_sum = $signed({horizontal_next[11], horizontal_next}) +
            $signed({vertical_next[11], vertical_next});
        planar_prediction = 8'(planar_sum >>> 4);
        prediction = mode_dc ? dc_value : planar_prediction;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            mode_dc <= 1'b1;
            reference_index <= 4'd0;
            pixel_x <= 3'd0;
            pixel_y <= 3'd0;
            reference_sum <= 12'd0;
            dc_value <= 8'd128;
            horizontal_accumulator <= 12'sd0;
            m_valid <= 1'b0;
            m_prediction <= 8'd0;
            m_residual <= 9'sd0;
            m_block_last <= 1'b0;
            done <= 1'b0;
            protocol_error <= 1'b0;
        end else begin
            done <= 1'b0;

            if (output_fire)
                m_valid <= 1'b0;

            if (start_fire) begin
                mode_dc <= luma_mode_dc;
                reference_index <= 4'd0;
                reference_sum <= 12'd0;
                pixel_x <= 3'd0;
                pixel_y <= 3'd0;
                horizontal_accumulator <= 12'sd0;
                protocol_error <= 1'b0;
                state <= LOAD_REFERENCES;
            end

            if (reference_fire) begin
                top_samples[reference_index] <= ref_top;
                left_samples[reference_index] <= ref_left;
                if (ref_last != (reference_index == 9))
                    protocol_error <= 1'b1;

                if ((reference_index >= 1) && (reference_index <= 8)) begin
                    reference_sum <= reference_sum + {2'd0, reference_pair};
                    vertical_accumulator[reference_index[2:0] - 1'b1] <=
                        $signed({1'b0, ref_top, 3'b000});
                    if (reference_index == 8)
                        dc_value <= 8'(dc_numerator >> 4);
                end

                if (reference_index == 9) begin
                    reference_index <= 4'd0;
                    state <= PROCESS_PIXELS;
                end else begin
                    reference_index <= reference_index + 1'b1;
                end
            end

            if (input_fire) begin
                m_valid <= 1'b1;
                m_prediction <= prediction;
                m_residual <= $signed({1'b0, s_pixel}) -
                    $signed({1'b0, prediction});
                m_block_last <= (pixel_x == 7) && (pixel_y == 7);
                horizontal_accumulator <= horizontal_next;
                vertical_accumulator[pixel_x] <= vertical_next;

                if (pixel_x == 7) begin
                    pixel_x <= 3'd0;
                    if (pixel_y == 7) begin
                        pixel_y <= 3'd0;
                        state <= DRAIN_OUTPUT;
                    end else begin
                        pixel_y <= pixel_y + 1'b1;
                    end
                end else begin
                    pixel_x <= pixel_x + 1'b1;
                end
            end

            if ((state == DRAIN_OUTPUT) && output_fire && m_block_last) begin
                state <= IDLE;
                done <= 1'b1;
            end
        end
    end
endmodule
