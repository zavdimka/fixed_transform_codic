module receiver_video_timing_720p #(
    parameter bit SIMULATION_STRIPE_BOUNDARIES = 1'b0
) (
    input  logic        pixel_clk,
    input  logic        rst_n,
    output logic [11:0] x,
    output logic [9:0]  y,
    output logic        data_enable,
    output logic        hsync,
    output logic        vsync,
    output logic        frame_start
);
    // CTA-861 1280x720p50: 74.25 MHz nominal, 1980x750 total.
    localparam logic [11:0] H_ACTIVE = 12'd1280;
    localparam logic [11:0] H_FRONT  = 12'd440;
    localparam logic [11:0] H_SYNC   = 12'd40;
    localparam logic [11:0] H_TOTAL  = 12'd1980;
    localparam logic [9:0] V_ACTIVE = 10'd720;
    localparam logic [9:0] V_FRONT  = 10'd5;
    localparam logic [9:0] V_SYNC   = 10'd5;
    localparam logic [9:0] V_TOTAL  = 10'd750;

    always_comb begin
        data_enable = (x < H_ACTIVE) && (y < V_ACTIVE);
        hsync = (x >= H_ACTIVE + H_FRONT)
             && (x < H_ACTIVE + H_FRONT + H_SYNC);
        // CTA progressive timings require the active VSYNC edge to coincide
        // exactly with the active HSYNC edge, not with x=0.
        if (y == V_ACTIVE + V_FRONT - 1'b1)
            vsync = x >= H_ACTIVE + H_FRONT;
        else if (y == V_ACTIVE + V_FRONT + V_SYNC - 1'b1)
            vsync = x < H_ACTIVE + H_FRONT;
        else
            vsync = (y >= V_ACTIVE + V_FRONT)
                 && (y < V_ACTIVE + V_FRONT + V_SYNC);
        frame_start = (x == 0) && (y == 0);
    end

    generate if (SIMULATION_STRIPE_BOUNDARIES) begin : accelerated_boundaries
        // One pixel-clock edge represents one real 16-line display boundary.
        // The testbench supplies this clock at 45 * frame_rate, preserving
        // wall-clock deadlines and bank CDC while skipping irrelevant pixels.
        always_ff @(posedge pixel_clk) begin
            x <= 12'd1290;
            if (!rst_n)
                y <= 10'd749;
            else if (y == 10'd749)
                y <= 10'd15;
            else if (y == 10'd719)
                y <= 10'd749;
            else
                y <= y + 10'd16;
        end
    end else begin : pixel_accurate_timing
        always_ff @(posedge pixel_clk) begin
            if (!rst_n) begin
                x <= 12'd0;
                y <= 10'd0;
            end else if (x == H_TOTAL - 1'b1) begin
                x <= 12'd0;
                if (y == V_TOTAL - 1'b1)
                    y <= 10'd0;
                else
                    y <= y + 1'b1;
            end else begin
                x <= x + 1'b1;
            end
        end
    end endgenerate
endmodule
