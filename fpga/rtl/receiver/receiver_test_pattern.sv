// Small, multiplier-free base-video source used before the radio decoder is
// available and later retained for board diagnostics.  The output latency is
// three pixel clocks, matching receiver_osd_framebuffer's mask/sync pipeline.
module receiver_test_pattern (
    input  logic        pixel_clk,
    input  logic        rst_n,
    input  logic [1:0]  mode,
    input  logic [11:0] x,
    input  logic [9:0]  y,
    output logic [23:0] rgb
);
    logic [23:0] pattern_comb;
    logic [23:0] rgb_d1, rgb_d2, rgb_d3;

    // Keep the diagnostic ramp as pure wiring. Bit 7 is always set, so a
    // synthesis or coordinate fault cannot turn all coloured bars black.
    // Active y=0..719 maps monotonically to 128..217 in eight-line steps,
    // fine enough to expose banding without adding arithmetic to this path.
    wire [7:0] bar_gradient = {1'b1, y[9:3]};
    wire [7:0] dark_gradient = {4'b0001, y[8:5]};

    always_comb begin
        case (mode)
            2'd0: pattern_comb = 24'h808080;

            // Eight 160-pixel bars with a common smooth luminance ramp.  Any
            // artifacts visible here are downstream of the video decoder.
            2'd1: begin
                if (x < 11'd160)
                    pattern_comb = {bar_gradient, bar_gradient, bar_gradient};
                else if (x < 11'd320)
                    pattern_comb = {bar_gradient, bar_gradient, 8'h00};
                else if (x < 11'd480)
                    pattern_comb = {8'h00, bar_gradient, bar_gradient};
                else if (x < 11'd640)
                    pattern_comb = {8'h00, bar_gradient, 8'h00};
                else if (x < 11'd800)
                    pattern_comb = {bar_gradient, 8'h00, bar_gradient};
                else if (x < 11'd960)
                    pattern_comb = {bar_gradient, 16'h0000};
                else if (x < 11'd1120)
                    pattern_comb = {16'h0000, bar_gradient};
                else
                    pattern_comb = {dark_gradient, dark_gradient,
                                    dark_gradient};
            end

            // 64-pixel grid over a checkerboard.  Useful for checking active
            // area, scaling, sync stability and OSD registration.
            2'd2: begin
                if ((x[5:0] == 0) || (y[5:0] == 0))
                    pattern_comb = 24'hFFFFFF;
                else if (x[6] ^ y[6])
                    pattern_comb = 24'h606060;
                else
                    pattern_comb = 24'h303030;
            end

            // Independent channel gradients expose swapped RGB/TMDS lanes or
            // bit-order errors without requiring a frame buffer.
            default: pattern_comb = {
                x[9:2], y[9:2], x[7:0] ^ y[7:0]
            };
        endcase
    end

    always_ff @(posedge pixel_clk) begin
        if (!rst_n) begin
            rgb_d1 <= 24'h808080;
            rgb_d2 <= 24'h808080;
            rgb_d3 <= 24'h808080;
            rgb <= 24'h808080;
        end else begin
            rgb_d1 <= pattern_comb;
            rgb_d2 <= rgb_d1;
            rgb_d3 <= rgb_d2;
            rgb <= rgb_d3;
        end
    end
endmodule
