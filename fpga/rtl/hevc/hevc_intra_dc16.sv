module hevc_intra_dc16 (
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
    logic [7:0] top_samples  [0:15];
    logic [7:0] left_samples [0:15];
    logic [12:0] reference_sum;
    logic [7:0] dc_value;
    logic [3:0] reference_index;
    logic [3:0] pixel_x;
    logic [3:0] pixel_y;
    logic [7:0] prediction;
    logic [12:0] reference_pair;
    logic [12:0] reference_sum_with_pair;
    logic [12:0] dc_numerator;
    logic [7:0] dc_next;

    assign ref_ready = state == LOAD_REFERENCES;
    assign s_ready = (state == PROCESS_PIXELS) && (!m_valid || m_ready);
    assign reference_pair = {5'd0, ref_top} + {5'd0, ref_left};
    assign reference_sum_with_pair = reference_sum + reference_pair;
    assign dc_numerator = reference_sum_with_pair + 13'd16;
    assign dc_next = 8'(dc_numerator >> 5);

    always_comb begin
        if ((pixel_x == 0) && (pixel_y == 0)) begin
            prediction = (left_samples[0] + (dc_value << 1)
                          + top_samples[0] + 2) >> 2;
        end else if (pixel_y == 0) begin
            prediction = (top_samples[pixel_x] + (dc_value << 1)
                          + dc_value + 2) >> 2;
        end else if (pixel_x == 0) begin
            prediction = (left_samples[pixel_y] + (dc_value << 1)
                          + dc_value + 2) >> 2;
        end else begin
            prediction = dc_value;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= LOAD_REFERENCES;
            reference_sum   <= '0;
            reference_index <= '0;
            dc_value        <= '0;
            pixel_x         <= '0;
            pixel_y         <= '0;
            m_valid         <= 1'b0;
            m_prediction    <= '0;
            m_residual      <= '0;
            m_block_last    <= 1'b0;
        end else begin
            if (m_valid && m_ready) begin
                m_valid <= 1'b0;
            end

            if (ref_valid && ref_ready) begin
                top_samples[reference_index]  <= ref_top;
                left_samples[reference_index] <= ref_left;
                if (reference_index == 15) begin
                    dc_value <= dc_next;
                    reference_sum   <= '0;
                    reference_index <= '0;
                    pixel_x         <= '0;
                    pixel_y         <= '0;
                    state           <= PROCESS_PIXELS;
                end else begin
                    reference_sum <= reference_sum_with_pair;
                    reference_index <= reference_index + 1'b1;
                end
            end

            if (s_valid && s_ready) begin
                m_valid      <= 1'b1;
                m_prediction <= prediction;
                m_residual   <= $signed({1'b0, s_pixel})
                              - $signed({1'b0, prediction});
                m_block_last <= (pixel_x == 15) && (pixel_y == 15);

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
