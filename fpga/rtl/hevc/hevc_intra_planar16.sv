module hevc_intra_planar16 (
    input  logic              clk,
    input  logic              rst_n,

    input  logic              ref_valid,
    output logic              ref_ready,
    input  logic [7:0]        ref_top,
    input  logic [7:0]        ref_left,

    input  logic              s_valid,
    output logic              s_ready,
    input  logic [7:0]        s_pixel,

    output logic              m_valid,
    input  logic              m_ready,
    output logic [7:0]        m_prediction,
    output logic signed [8:0] m_residual,
    output logic              m_block_last
);
    typedef enum logic { LOAD_REFERENCES, PROCESS_PIXELS } state_t;

    state_t state;
    logic [7:0] filtered_top  [0:17];
    logic [7:0] filtered_left [0:17];
    logic signed [13:0] vertical_accumulator [0:15];
    logic signed [13:0] horizontal_accumulator;

    logic [4:0] reference_index;
    logic [3:0] pixel_x;
    logic [3:0] pixel_y;
    logic [4:0] top_reference_index;
    logic [4:0] left_reference_index;
    logic [3:0] vertical_init_index;

    logic [7:0] previous_top;
    logic [7:0] previous_left;
    logic [7:0] previous_previous_top;
    logic [7:0] previous_previous_left;
    logic [7:0] filtered_top_next;
    logic [7:0] filtered_left_next;

    logic signed [13:0] horizontal_start;
    logic signed [13:0] horizontal_next;
    logic signed [13:0] vertical_next;
    logic [7:0] prediction;

    assign ref_ready = state == LOAD_REFERENCES;
    assign s_ready = (state == PROCESS_PIXELS) && (!m_valid || m_ready);
    assign top_reference_index = {1'b0, pixel_x} + 5'd1;
    assign left_reference_index = {1'b0, pixel_y} + 5'd1;
    assign vertical_init_index = reference_index[3:0] - 4'd2;

    always_comb begin
        if (reference_index == 1) begin
            filtered_top_next = 8'(({2'b0, ref_left}
                                  + {1'b0, previous_top, 1'b0}
                                  + {2'b0, ref_top} + 10'd2) >> 2);
            filtered_left_next = filtered_top_next;
        end else begin
            filtered_top_next = 8'(({2'b0, previous_previous_top}
                                  + {1'b0, previous_top, 1'b0}
                                  + {2'b0, ref_top} + 10'd2) >> 2);
            filtered_left_next = 8'(({2'b0, previous_previous_left}
                                   + {1'b0, previous_left, 1'b0}
                                   + {2'b0, ref_left} + 10'd2) >> 2);
        end
    end

    always_comb begin
        horizontal_start = $signed({1'b0,
                                    filtered_left[left_reference_index],
                                    4'b0}) + 14'sd16;
        horizontal_next = ((pixel_x == 0)
                           ? horizontal_start : horizontal_accumulator)
                        + $signed({5'b0, filtered_top[17]})
                        - $signed({5'b0,
                                   filtered_left[left_reference_index]});
        vertical_next = vertical_accumulator[pixel_x]
                      + $signed({5'b0, filtered_left[17]})
                      - $signed({5'b0,
                                 filtered_top[top_reference_index]});
        prediction = 8'((horizontal_next + vertical_next) >>> 5);
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state                       <= LOAD_REFERENCES;
            reference_index             <= '0;
            previous_top                <= '0;
            previous_left               <= '0;
            previous_previous_top       <= '0;
            previous_previous_left      <= '0;
            pixel_x                     <= '0;
            pixel_y                     <= '0;
            horizontal_accumulator      <= '0;
            m_valid                     <= 1'b0;
            m_prediction                <= '0;
            m_residual                  <= '0;
            m_block_last                <= 1'b0;
        end else begin
            if (m_valid && m_ready) begin
                m_valid <= 1'b0;
            end

            if (ref_valid && ref_ready) begin
                if (reference_index != 0) begin
                    filtered_top[reference_index - 1'b1]
                        <= filtered_top_next;
                    filtered_left[reference_index - 1'b1]
                        <= filtered_left_next;
                    if ((reference_index >= 2) &&
                        (reference_index <= 17)) begin
                        vertical_accumulator[vertical_init_index]
                            <= $signed({2'b0, filtered_top_next, 4'b0});
                    end
                end

                previous_previous_top  <= previous_top;
                previous_previous_left <= previous_left;
                previous_top           <= ref_top;
                previous_left          <= ref_left;

                if (reference_index == 18) begin
                    reference_index        <= '0;
                    pixel_x                <= '0;
                    pixel_y                <= '0;
                    horizontal_accumulator <= '0;
                    state                  <= PROCESS_PIXELS;
                end else begin
                    reference_index <= reference_index + 1'b1;
                end
            end

            if (s_valid && s_ready) begin
                m_valid                <= 1'b1;
                m_prediction           <= prediction;
                m_residual             <= $signed({1'b0, s_pixel})
                                        - $signed({1'b0, prediction});
                m_block_last           <= (pixel_x == 15) && (pixel_y == 15);
                horizontal_accumulator <= horizontal_next;
                vertical_accumulator[pixel_x] <= vertical_next;

                if (pixel_x == 15) begin
                    pixel_x <= '0;
                    if (pixel_y == 15) begin
                        pixel_y <= '0;
                        state   <= LOAD_REFERENCES;
                    end else begin
                        pixel_y <= pixel_y + 1'b1;
                    end
                end else begin
                    pixel_x <= pixel_x + 1'b1;
                end
            end
        end
    end
endmodule
