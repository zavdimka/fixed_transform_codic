// Bridges one 10-bit TMDS word per pixel to the Efinix 5:1 LTX parallel port.
// The half-pixel and pixel clocks are synchronous outputs of the same PLL.
// Registering on the falling half-pixel edge avoids the coincident rising-edge
// setup path: TMDS has 3.36 ns to reach this register and LTX has another
// 3.36 ns before sampling its five parallel bits on the next rising edge.
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
