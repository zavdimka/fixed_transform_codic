module receiver_video_timing_720p (
    input  logic        pixel_clk,
    input  logic        rst_n,
    output logic [10:0] x,
    output logic [9:0]  y,
    output logic        data_enable,
    output logic        hsync,
    output logic        vsync,
    output logic        frame_start
);
    localparam logic [10:0] H_ACTIVE = 11'd1280;
    localparam logic [10:0] H_FRONT  = 11'd110;
    localparam logic [10:0] H_SYNC   = 11'd40;
    localparam logic [10:0] H_TOTAL  = 11'd1650;
    localparam logic [9:0] V_ACTIVE = 10'd720;
    localparam logic [9:0] V_FRONT  = 10'd5;
    localparam logic [9:0] V_SYNC   = 10'd5;
    localparam logic [9:0] V_TOTAL  = 10'd750;

    always_comb begin
        data_enable = (x < H_ACTIVE) && (y < V_ACTIVE);
        hsync = (x >= H_ACTIVE + H_FRONT)
             && (x < H_ACTIVE + H_FRONT + H_SYNC);
        vsync = (y >= V_ACTIVE + V_FRONT)
             && (y < V_ACTIVE + V_FRONT + V_SYNC);
        frame_start = (x == 0) && (y == 0);
    end

    always_ff @(posedge pixel_clk) begin
        if (!rst_n) begin
            x <= 11'd0;
            y <= 10'd0;
        end else if (x == H_TOTAL - 1'b1) begin
            x <= 11'd0;
            if (y == V_TOTAL - 1'b1)
                y <= 10'd0;
            else
                y <= y + 1'b1;
        end else begin
            x <= x + 1'b1;
        end
    end
endmodule
