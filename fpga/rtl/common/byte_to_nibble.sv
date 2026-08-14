module byte_to_nibble (
    input  logic       clk,
    input  logic       rst_n,

    input  logic       s_valid,
    output logic       s_ready,
    input  logic [7:0] s_data,

    output logic       m_valid,
    input  logic       m_ready,
    output logic [3:0] m_data
);
    logic [7:0] byte_buffer;
    logic       busy;
    logic       low_nibble;

    // A new byte may replace the current byte on the same cycle in which its
    // low nibble is accepted. This sustains one nibble per clock without a
    // bubble between bytes.
    assign s_ready = !busy || (low_nibble && m_ready);
    assign m_valid = busy;
    assign m_data  = low_nibble ? byte_buffer[3:0] : byte_buffer[7:4];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            byte_buffer <= '0;
            busy        <= 1'b0;
            low_nibble  <= 1'b0;
        end else if (!busy) begin
            if (s_valid) begin
                byte_buffer <= s_data;
                busy        <= 1'b1;
                low_nibble  <= 1'b0;
            end
        end else if (m_ready) begin
            if (!low_nibble) begin
                low_nibble <= 1'b1;
            end else if (s_valid) begin
                byte_buffer <= s_data;
                busy        <= 1'b1;
                low_nibble  <= 1'b0;
            end else begin
                busy       <= 1'b0;
                low_nibble <= 1'b0;
            end
        end
    end
endmodule
