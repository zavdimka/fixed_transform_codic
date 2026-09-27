// DVI-compatible TMDS transmitter for the selected 1280x720 raster timing.
// Blanking contains only control symbols: no HDMI preambles, guard bands,
// data islands, audio, or AVI InfoFrames.
module receiver_hdmi_tx (
    input logic pixel_clk, rst_n,
    input logic [11:0] x,
    input logic [9:0] y,
    input logic [23:0] rgb,
    input logic data_enable, hsync, vsync,
    output logic [9:0] tmds_blue, tmds_green, tmds_red
);
    localparam logic [2:0] CONTROL=0, VIDEO=1;
    logic [2:0] mode;
    logic [1:0] blue_control, green_control, red_control;

    always_comb begin
        mode = data_enable ? VIDEO : CONTROL;
        blue_control = {vsync, hsync};
        green_control = 2'b00;
        red_control = 2'b00;
    end

    receiver_hdmi_channel #(.CHANNEL(0)) blue_channel (
        .pixel_clk(pixel_clk),.rst_n(rst_n),.video_data(rgb[7:0]),
        .control_data(blue_control),.island_data(4'b0),.mode(mode),
        .tmds_word(tmds_blue));
    receiver_hdmi_channel #(.CHANNEL(1)) green_channel (
        .pixel_clk(pixel_clk),.rst_n(rst_n),.video_data(rgb[15:8]),
        .control_data(green_control),.island_data(4'b0),.mode(mode),
        .tmds_word(tmds_green));
    receiver_hdmi_channel #(.CHANNEL(2)) red_channel (
        .pixel_clk(pixel_clk),.rst_n(rst_n),.video_data(rgb[23:16]),
        .control_data(red_control),.island_data(4'b0),.mode(mode),
        .tmds_word(tmds_red));
endmodule

module receiver_hdmi_channel #(parameter integer CHANNEL=0) (
    input logic pixel_clk, rst_n,
    input logic [7:0] video_data,
    input logic [1:0] control_data,
    input logic [3:0] island_data,
    input logic [2:0] mode,
    output logic [9:0] tmds_word
);
    logic signed [5:0] disparity;
    logic [8:0] q_m;
    logic [3:0] q_m_ones, input_ones;
    logic signed [5:0] q_m_balance;
    logic use_xnor;
    logic [9:0] control_word, terc4_word, video_guard_word;
    integer i;

    always_comb begin
        input_ones=0;
        for(i=0;i<8;i=i+1) input_ones=input_ones+video_data[i];
        use_xnor=(input_ones>4)||((input_ones==4)&&!video_data[0]);
        q_m[0]=video_data[0];
        for(i=1;i<8;i=i+1)
            q_m[i]=use_xnor ? ~(q_m[i-1]^video_data[i])
                            :  (q_m[i-1]^video_data[i]);
        q_m[8]=!use_xnor;
        q_m_ones=0;
        for(i=0;i<8;i=i+1) q_m_ones=q_m_ones+q_m[i];
        q_m_balance=$signed({1'b0,q_m_ones,1'b0})-6'sd8;
        case(control_data)
            0:control_word=10'b1101010100; 1:control_word=10'b0010101011;
            2:control_word=10'b0101010100; default:control_word=10'b1010101011;
        endcase
        case(island_data)
            4'h0:terc4_word=10'b1010011100; 4'h1:terc4_word=10'b1001100011;
            4'h2:terc4_word=10'b1011100100; 4'h3:terc4_word=10'b1011100010;
            4'h4:terc4_word=10'b0101110001; 4'h5:terc4_word=10'b0100011110;
            4'h6:terc4_word=10'b0110001110; 4'h7:terc4_word=10'b0100111100;
            4'h8:terc4_word=10'b1011001100; 4'h9:terc4_word=10'b0100111001;
            4'hA:terc4_word=10'b0110011100; 4'hB:terc4_word=10'b1011000110;
            4'hC:terc4_word=10'b1010001110; 4'hD:terc4_word=10'b1001110001;
            4'hE:terc4_word=10'b0101100011; default:terc4_word=10'b1011000011;
        endcase
        video_guard_word=(CHANNEL==1)?10'b0100110011:10'b1011001100;
    end

    always_ff @(posedge pixel_clk) begin
        if(!rst_n) begin
            disparity<=0; tmds_word<=10'b1101010100;
        end else if(mode!=3'd1) begin
            disparity<=0;
            case(mode)
                3'd2:tmds_word<=video_guard_word;
                3'd3:tmds_word<=terc4_word;
                3'd4:begin
                    if(CHANNEL==0)
                        case(control_data)
                            0:tmds_word<=10'b1010001110;
                            1:tmds_word<=10'b1001110001;
                            2:tmds_word<=10'b0101100011;
                            default:tmds_word<=10'b1011000011;
                        endcase
                    else tmds_word<=10'b0100110011;
                end
                default:tmds_word<=control_word;
            endcase
        end else if((disparity==0)||(q_m_balance==0)) begin
            tmds_word[9]<=~q_m[8]; tmds_word[8]<=q_m[8];
            tmds_word[7:0]<=q_m[8]?q_m[7:0]:~q_m[7:0];
            disparity <= disparity
                       + (q_m[8] ? q_m_balance : -q_m_balance);
        end else if(((disparity>0)&&(q_m_balance>0))
                 || ((disparity<0)&&(q_m_balance<0))) begin
            tmds_word<={1'b1,q_m[8],~q_m[7:0]};
            disparity<=disparity-q_m_balance+(q_m[8]?6'sd2:6'sd0);
        end else begin
            tmds_word<={1'b0,q_m[8],q_m[7:0]};
            disparity<=disparity+q_m_balance-(q_m[8]?6'sd0:6'sd2);
        end
    end
endmodule
