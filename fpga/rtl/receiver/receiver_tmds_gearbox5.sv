// Bridges one 10-bit TMDS word per pixel to the Efinix 5:1 LTX parallel port.
// The half-pixel and pixel clocks are synchronous outputs of the same PLL.
// Registering on the falling half-pixel edge avoids the coincident rising-edge
// setup path: TMDS has 3.36 ns to reach this register and LTX has another
// 3.36 ns before sampling its five parallel bits on the next rising edge.
// rst_n must be released by a pixel-clock register, not by an independent
// half-pixel synchronizer, so half_phase always starts on the same one of the
// two half-pixel slots.
module receiver_tmds_gearbox5 (
    input  logic       half_pixel_clk,
    input  logic       rst_n,
    input  logic [9:0] tmds_word,
    output logic [4:0] serializer_data
);
    logic half_phase;

    always_ff @(negedge half_pixel_clk) begin
        if (!rst_n) begin
            half_phase <= 1'b0;
            serializer_data <= 5'd0;
        end else begin
            half_phase <= ~half_phase;
            if (half_phase)
                serializer_data <= tmds_word[9:5];
            else
                serializer_data <= tmds_word[4:0];
        end
    end
endmodule

// Three-lane variant used by the receiver top level. All lanes share the
// same word boundary detector, so placement-dependent reset skew cannot put
// one TMDS lane into the opposite five-bit half. pixel_word_toggle changes
// whenever the pixel-clock domain produces a new set of TMDS words. The
// gearbox therefore re-aligns itself every pixel instead of relying on a
// free-running divide-by-two phase that is only correct after reset.
module receiver_tmds_gearbox5x3 (
    input  logic       half_pixel_clk,
    input  logic       rst_n,
    input  logic       pixel_word_toggle,
    input  logic [9:0] tmds_word0,
    input  logic [9:0] tmds_word1,
    input  logic [9:0] tmds_word2,
    output logic [4:0] serializer_data0,
    output logic [4:0] serializer_data1,
    output logic [4:0] serializer_data2
);
    logic seen_word_toggle;

    always_ff @(negedge half_pixel_clk) begin
        if (!rst_n) begin
            seen_word_toggle <= pixel_word_toggle;
            serializer_data0 <= 5'd0;
            serializer_data1 <= 5'd0;
            serializer_data2 <= 5'd0;
        end else if (pixel_word_toggle != seen_word_toggle) begin
            seen_word_toggle <= pixel_word_toggle;
            serializer_data0 <= tmds_word0[4:0];
            serializer_data1 <= tmds_word1[4:0];
            serializer_data2 <= tmds_word2[4:0];
        end else begin
            serializer_data0 <= tmds_word0[9:5];
            serializer_data1 <= tmds_word1[9:5];
            serializer_data2 <= tmds_word2[9:5];
        end
    end
endmodule
