// DVI/HDMI TMDS channel encoder. The control symbols and running-disparity
// rules match HDMI 1.x/DVI; the surrounding receiver sends video-only DVI.
module receiver_tmds_channel (
    input  logic       pixel_clk,
    input  logic       rst_n,
    input  logic [7:0] video_data,
    input  logic [1:0] control_data,
    input  logic       data_enable,
    output logic [9:0] tmds_word
);
    logic signed [5:0] disparity;
    logic [8:0] q_m;
    logic [3:0] q_m_ones;
    logic signed [5:0] q_m_balance;
    logic [3:0] input_ones;
    logic use_xnor;
    integer bit_index;

    always_comb begin
        input_ones = 4'd0;
        for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1)
            input_ones = input_ones + {3'd0, video_data[bit_index]};

        use_xnor = (input_ones > 4) ||
                   ((input_ones == 4) && !video_data[0]);
        q_m[0] = video_data[0];
        q_m[1] = use_xnor ? ~(q_m[0] ^ video_data[1])
                          :  (q_m[0] ^ video_data[1]);
        q_m[2] = use_xnor ? ~(q_m[1] ^ video_data[2])
                          :  (q_m[1] ^ video_data[2]);
        q_m[3] = use_xnor ? ~(q_m[2] ^ video_data[3])
                          :  (q_m[2] ^ video_data[3]);
        q_m[4] = use_xnor ? ~(q_m[3] ^ video_data[4])
                          :  (q_m[3] ^ video_data[4]);
        q_m[5] = use_xnor ? ~(q_m[4] ^ video_data[5])
                          :  (q_m[4] ^ video_data[5]);
        q_m[6] = use_xnor ? ~(q_m[5] ^ video_data[6])
                          :  (q_m[5] ^ video_data[6]);
        q_m[7] = use_xnor ? ~(q_m[6] ^ video_data[7])
                          :  (q_m[6] ^ video_data[7]);
        q_m[8] = !use_xnor;

        q_m_ones = 4'd0;
        for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1)
            q_m_ones = q_m_ones + {3'd0, q_m[bit_index]};
        q_m_balance = $signed({1'b0, q_m_ones, 1'b0}) - 6'sd8;
    end

    always_ff @(posedge pixel_clk) begin
        if (!rst_n) begin
            disparity <= 6'sd0;
            tmds_word <= 10'b1101010100;
        end else if (!data_enable) begin
            disparity <= 6'sd0;
            case (control_data)
                2'b00: tmds_word <= 10'b1101010100;
                2'b01: tmds_word <= 10'b0010101011;
                2'b10: tmds_word <= 10'b0101010100;
                default: tmds_word <= 10'b1010101011;
            endcase
        end else if ((disparity == 0) || (q_m_balance == 0)) begin
            tmds_word[9] <= ~q_m[8];
            tmds_word[8] <= q_m[8];
            tmds_word[7:0] <= q_m[8] ? q_m[7:0] : ~q_m[7:0];
            disparity <= q_m[8] ? q_m_balance : -q_m_balance;
        end else if (((disparity > 0) && (q_m_balance > 0))
                     || ((disparity < 0) && (q_m_balance < 0))) begin
            tmds_word[9] <= 1'b1;
            tmds_word[8] <= q_m[8];
            tmds_word[7:0] <= ~q_m[7:0];
            disparity <= disparity - q_m_balance
                       + (q_m[8] ? 6'sd2 : 6'sd0);
        end else begin
            tmds_word[9] <= 1'b0;
            tmds_word[8] <= q_m[8];
            tmds_word[7:0] <= q_m[7:0];
            disparity <= disparity + q_m_balance
                       - (q_m[8] ? 6'sd0 : 6'sd2);
        end
    end
endmodule
