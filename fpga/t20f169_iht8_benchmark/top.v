`timescale 1ns/1ps

module t20f169_receiver (
    input  wire       CLK_48Mhz,
    output wire       pll_reset,
    input  wire       pll_lock,
    input  wire       pll_60Mhz,
    input  wire       pll_24Mhz,
    output wire       pll2_reset,
    input  wire       pll2_lock,
    input  wire       hdmi_fast_clk,
    input  wire       hdmi_half_pixel_clk,
    input  wire       hdmi_pixel_clk,
    output wire [4:0] hdmi_data0_5b,
    output wire [4:0] hdmi_data1_5b,
    output wire [4:0] hdmi_data2_5b,
    input  wire       SPI_CLK,
    input  wire       SPI_CS,
    input  wire       SPI_MOSI,
    output wire       SPI_MISO,
    input  wire       PAR_CS,
    output wire       PAR_CLK,
    input  wire [3:0] PAR_D,
    output wire [5:0] LED,
    output wire       CSI_MCLK,
    input  wire       CSI_PCLK,
    input  wire       CSI_VSYNC,
    input  wire       CSI_HSYNC,
    input  wire [7:0] CSI_D
);
    localparam [1:0] LOAD_START = 2'd0;
    localparam [1:0] LOAD_COEFFICIENT = 2'd1;
    localparam [1:0] LOAD_COMMIT = 2'd2;

    reg [3:0] reset_pipe;
    wire reset_n = reset_pipe[3];
    always @(posedge pll_60Mhz or negedge pll_lock) begin
        if (!pll_lock)
            reset_pipe <= 4'd0;
        else
            reset_pipe <= {reset_pipe[2:0], 1'b1};
    end

    reg [1:0] load_state;
    reg [3:0] event_index;
    reg [6:0] block_counter;
    reg [11:0] coefficient_lfsr;
    reg [15:0] output_checksum;
    reg activity_24;
    reg activity_fast;
    reg activity_half;
    reg activity_pixel;
    reg activity_csi;

    always @(posedge pll_24Mhz)
        activity_24 <= ~activity_24 ^ PAR_CS;
    always @(posedge hdmi_fast_clk)
        activity_fast <= ~activity_fast;
    always @(posedge hdmi_half_pixel_clk)
        activity_half <= ~activity_half;
    always @(posedge hdmi_pixel_clk)
        activity_pixel <= ~activity_pixel;
    always @(posedge CSI_PCLK)
        activity_csi <= ~activity_csi ^ CSI_VSYNC ^ CSI_HSYNC;

    wire load_start_ready;
    wire load_coeff_ready;
    wire load_commit_ready;
    wire pixel_valid;
    wire [5:0] pixel_index;
    wire signed [15:0] pixel_residual;
    wire pixel_last;
    wire [6:0] pixel_ctu_index;
    wire [2:0] pixel_block_index;
    wire [1:0] pixel_plane;
    wire [1:0] pixel_mode;
    wire decoder_busy;
    wire limit_error;
    wire duplicate_error;
    wire [31:0] completed_block_count;

    wire start_fire = (load_state == LOAD_START) && load_start_ready;
    wire coefficient_fire = (load_state == LOAD_COEFFICIENT)
                          && load_coeff_ready;
    wire commit_fire = (load_state == LOAD_COMMIT) && load_commit_ready;

    always @(posedge pll_60Mhz) begin
        if (!reset_n) begin
            load_state <= LOAD_START;
            event_index <= 4'd0;
            block_counter <= 7'd0;
            coefficient_lfsr <= 12'h5a7;
            output_checksum <= 16'd0;
        end else begin
            if (start_fire) begin
                load_state <= LOAD_COEFFICIENT;
                event_index <= 4'd0;
            end
            if (coefficient_fire) begin
                coefficient_lfsr <= {
                    coefficient_lfsr[10:0],
                    coefficient_lfsr[11] ^ coefficient_lfsr[8]
                };
                if (event_index == 4'd12)
                    load_state <= LOAD_COMMIT;
                else
                    event_index <= event_index + 1'b1;
            end
            if (commit_fire) begin
                load_state <= LOAD_START;
                block_counter <= block_counter + 1'b1;
            end
            if (pixel_valid)
                output_checksum <= output_checksum
                                 ^ pixel_residual
                                 ^ {10'd0, pixel_index}
                                 ^ {9'd0, pixel_ctu_index};
        end
    end

    receiver_bounded_sparse_iht8 decoder (
        .clk(pll_60Mhz),
        .rst_n(reset_n),
        .load_start_valid(load_state == LOAD_START),
        .load_start_ready(load_start_ready),
        .load_ctu_index(block_counter),
        .load_block_index(block_counter[2:0]),
        .load_plane(2'd0),
        .load_mode(block_counter[1:0]),
        .load_quant_shift(block_counter[5:3]),
        .load_coeff_valid(load_state == LOAD_COEFFICIENT),
        .load_coeff_ready(load_coeff_ready),
        .load_coeff_address(event_index == 0 ? 6'd0
                                             : {2'd0, event_index}),
        .load_coeff_data($signed(coefficient_lfsr)),
        .load_commit_valid(load_state == LOAD_COMMIT),
        .load_commit_ready(load_commit_ready),
        .load_abort(1'b0),
        .pixel_valid(pixel_valid),
        .pixel_ready(1'b1),
        .pixel_index(pixel_index),
        .pixel_residual(pixel_residual),
        .pixel_last(pixel_last),
        .pixel_ctu_index(pixel_ctu_index),
        .pixel_block_index(pixel_block_index),
        .pixel_plane(pixel_plane),
        .pixel_mode(pixel_mode),
        .busy(decoder_busy),
        .limit_error(limit_error),
        .duplicate_error(duplicate_error),
        .completed_block_count(completed_block_count)
    );

    assign pll_reset = 1'b1;
    assign pll2_reset = 1'b1;
    assign PAR_CLK = activity_24;
    assign CSI_MCLK = 1'b0;
    assign SPI_MISO = decoder_busy ^ limit_error ^ duplicate_error
                    ^ SPI_CLK ^ SPI_CS ^ SPI_MOSI ^ PAR_CS ^ ^PAR_D
                    ^ CLK_48Mhz ^ pll2_lock ^ activity_fast
                    ^ activity_half ^ activity_pixel ^ activity_csi
                    ^ CSI_VSYNC ^ CSI_HSYNC ^ ^CSI_D;
    assign LED = output_checksum[5:0] ^ completed_block_count[5:0];
    assign hdmi_data0_5b = output_checksum[4:0];
    assign hdmi_data1_5b = {pixel_last, pixel_block_index, pixel_plane[0]};
    assign hdmi_data2_5b = {pixel_mode, completed_block_count[2:0]};
endmodule
