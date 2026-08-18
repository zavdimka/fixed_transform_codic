module custom_satd4x4 (
    input  logic                clk,
    input  logic                rst_n,

    input  logic                s_valid,
    input  logic                s_tag,
    input  logic signed [143:0] s_samples,

    output logic                m_valid,
    output logic                m_tag,
    output logic [15:0]         m_satd
);
    logic signed [10:0] horizontal [0:15];
    logic signed [10:0] horizontal_next [0:15];
    logic signed [12:0] vertical [0:15];
    logic signed [12:0] vertical_next [0:15];
    logic valid_h, valid_v;
    logic tag_h, tag_v;
    logic [16:0] absolute_sum;
    integer comb_row, column, sequential_row;
    logic signed [9:0] h_a0, h_a1, h_a2, h_a3;
    logic signed [11:0] v_a0, v_a1, v_a2, v_a3;
    logic [12:0] magnitudes [0:15];
    logic [13:0] pair_sum [0:7];
    logic [14:0] quad_sum [0:3];
    logic [15:0] half_sum [0:1];

    function automatic logic [12:0] magnitude13(
        input logic signed [12:0] value
    );
        magnitude13 = value[12] ? $unsigned(-value) : $unsigned(value);
    endfunction

    always_comb begin
        for (comb_row = 0; comb_row < 4; comb_row = comb_row + 1) begin
            h_a0 = $signed(s_samples[(comb_row * 4) * 9 +: 9])
                 + $signed(s_samples[(comb_row * 4 + 3) * 9 +: 9]);
            h_a1 = $signed(s_samples[(comb_row * 4 + 1) * 9 +: 9])
                 + $signed(s_samples[(comb_row * 4 + 2) * 9 +: 9]);
            h_a2 = $signed(s_samples[(comb_row * 4 + 1) * 9 +: 9])
                 - $signed(s_samples[(comb_row * 4 + 2) * 9 +: 9]);
            h_a3 = $signed(s_samples[(comb_row * 4) * 9 +: 9])
                 - $signed(s_samples[(comb_row * 4 + 3) * 9 +: 9]);
            horizontal_next[comb_row * 4] =
                $signed({h_a0[9], h_a0}) + $signed({h_a1[9], h_a1});
            horizontal_next[comb_row * 4 + 1] =
                $signed({h_a3[9], h_a3}) + $signed({h_a2[9], h_a2});
            horizontal_next[comb_row * 4 + 2] =
                $signed({h_a0[9], h_a0}) - $signed({h_a1[9], h_a1});
            horizontal_next[comb_row * 4 + 3] =
                $signed({h_a3[9], h_a3}) - $signed({h_a2[9], h_a2});
        end

        for (column = 0; column < 4; column = column + 1) begin
            v_a0 = $signed({horizontal[column][10], horizontal[column]})
                 + $signed({horizontal[12 + column][10], horizontal[12 + column]});
            v_a1 = $signed({horizontal[4 + column][10], horizontal[4 + column]})
                 + $signed({horizontal[8 + column][10], horizontal[8 + column]});
            v_a2 = $signed({horizontal[4 + column][10], horizontal[4 + column]})
                 - $signed({horizontal[8 + column][10], horizontal[8 + column]});
            v_a3 = $signed({horizontal[column][10], horizontal[column]})
                 - $signed({horizontal[12 + column][10], horizontal[12 + column]});
            vertical_next[column] =
                $signed({v_a0[11], v_a0}) + $signed({v_a1[11], v_a1});
            vertical_next[4 + column] =
                $signed({v_a3[11], v_a3}) + $signed({v_a2[11], v_a2});
            vertical_next[8 + column] =
                $signed({v_a0[11], v_a0}) - $signed({v_a1[11], v_a1});
            vertical_next[12 + column] =
                $signed({v_a3[11], v_a3}) - $signed({v_a2[11], v_a2});
        end

        for (column = 0; column < 16; column = column + 1)
            magnitudes[column] = magnitude13(vertical[column]);
        for (column = 0; column < 8; column = column + 1)
            pair_sum[column] = {1'b0, magnitudes[column * 2]}
                             + {1'b0, magnitudes[column * 2 + 1]};
        for (column = 0; column < 4; column = column + 1)
            quad_sum[column] = {1'b0, pair_sum[column * 2]}
                             + {1'b0, pair_sum[column * 2 + 1]};
        half_sum[0] = {1'b0, quad_sum[0]} + {1'b0, quad_sum[1]};
        half_sum[1] = {1'b0, quad_sum[2]} + {1'b0, quad_sum[3]};
        absolute_sum = {1'b0, half_sum[0]} + {1'b0, half_sum[1]};
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            valid_h <= 1'b0;
            valid_v <= 1'b0;
            m_valid <= 1'b0;
        end else begin
            valid_h <= s_valid;
            valid_v <= valid_h;
            m_valid <= valid_v;
            tag_h <= s_tag;
            tag_v <= tag_h;
            m_tag <= tag_v;

            if (s_valid) begin
                for (sequential_row = 0; sequential_row < 16;
                     sequential_row = sequential_row + 1)
                    horizontal[sequential_row] <= horizontal_next[sequential_row];
            end
            if (valid_h) begin
                for (sequential_row = 0; sequential_row < 16;
                     sequential_row = sequential_row + 1)
                    vertical[sequential_row] <= vertical_next[sequential_row];
            end
            if (valid_v)
                m_satd <= absolute_sum[15:0];
        end
    end
endmodule
