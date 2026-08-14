module hevc_prediction_buffer16 (
    input  logic       clk,
    input  logic       write_enable,
    input  logic [7:0] write_address,
    input  logic [7:0] write_data,
    input  logic       read_enable,
    input  logic [7:0] read_address,
    output logic [7:0] read_data
);
    logic [7:0] memory [0:255];

    always_ff @(posedge clk) begin
        if (write_enable) begin
            memory[write_address] <= write_data;
        end
        if (read_enable) begin
            read_data <= memory[read_address];
        end
    end
endmodule
