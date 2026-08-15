module hevc_reconstruct #(
    parameter integer RESIDUAL_WIDTH = 16
) (
    input  logic                             clk,
    input  logic                             rst_n,
    input  logic                             s_valid,
    output logic                             s_ready,
    input  logic [7:0]                       s_prediction,
    input  logic signed [RESIDUAL_WIDTH-1:0] s_residual,
    output logic                             m_valid,
    input  logic                             m_ready,
    output logic [7:0]                       m_reconstructed
);
    logic signed [RESIDUAL_WIDTH:0] reconstruction_sum;

    assign s_ready = !m_valid || m_ready;
    assign reconstruction_sum =
        $signed({{(RESIDUAL_WIDTH-8){1'b0}}, 1'b0, s_prediction})
        + $signed({s_residual[RESIDUAL_WIDTH-1], s_residual});

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            m_valid         <= 1'b0;
            m_reconstructed <= '0;
        end else begin
            if (m_valid && m_ready) begin
                m_valid <= 1'b0;
            end
            if (s_valid && s_ready) begin
                m_valid <= 1'b1;
                if (reconstruction_sum < 0) begin
                    m_reconstructed <= 8'd0;
                end else if (reconstruction_sum > 255) begin
                    m_reconstructed <= 8'd255;
                end else begin
                    m_reconstructed <= reconstruction_sum[7:0];
                end
            end
        end
    end

    initial begin
        if (RESIDUAL_WIDTH < 9) begin
            $error("RESIDUAL_WIDTH must be at least 9");
        end
    end
endmodule
