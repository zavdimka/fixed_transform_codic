module hevc_prediction_buffer8 (
    input logic clk, input logic write_enable, input logic [5:0] write_address,
    input logic [7:0] write_data, input logic read_enable, input logic [5:0] read_address,
    output logic [7:0] read_data
);
    logic [7:0] memory [0:63];
    always_ff @(posedge clk) begin
        if (write_enable) memory[write_address] <= write_data;
        if (read_enable) read_data <= memory[read_address];
    end
endmodule
