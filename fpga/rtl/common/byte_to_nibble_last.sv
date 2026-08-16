module byte_to_nibble_last (
    input  logic       clk,
    input  logic       rst_n,

    input  logic       s_valid,
    output logic       s_ready,
    input  logic [7:0] s_data,
    input  logic       s_last,

    output logic       m_valid,
    input  logic       m_ready,
    output logic [3:0] m_data,
    output logic       m_last
);
    logic [7:0] byte_buffer;
    logic       last_buffer;
    logic       busy;
    logic       low_nibble;

    assign s_ready = !busy || (low_nibble && m_ready);
    assign m_valid = busy;
    assign m_data = low_nibble ? byte_buffer[3:0] : byte_buffer[7:4];
    assign m_last = busy && low_nibble && last_buffer;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            byte_buffer <= 8'd0;
            last_buffer <= 1'b0;
            busy <= 1'b0;
            low_nibble <= 1'b0;
        end else if (!busy) begin
            if (s_valid) begin
                byte_buffer <= s_data;
                last_buffer <= s_last;
                busy <= 1'b1;
                low_nibble <= 1'b0;
            end
        end else if (m_ready) begin
            if (!low_nibble) begin
                low_nibble <= 1'b1;
            end else if (s_valid) begin
                byte_buffer <= s_data;
                last_buffer <= s_last;
                busy <= 1'b1;
                low_nibble <= 1'b0;
            end else begin
                busy <= 1'b0;
                low_nibble <= 1'b0;
            end
        end
    end
endmodule
