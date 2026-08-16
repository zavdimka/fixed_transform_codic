module hevc_prediction_buffer16 #(
    parameter integer DATA_WIDTH = 8
) (
    input  logic       clk,
    input  logic       write_enable,
    input  logic [7:0] write_address,
    input  logic [DATA_WIDTH-1:0] write_data,
    input  logic       read_enable,
    input  logic [7:0] read_address,
    output logic [DATA_WIDTH-1:0] read_data
);
    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    logic [DATA_WIDTH-1:0] memory [0:255];

    always_ff @(posedge clk) begin
        if (write_enable) begin
            memory[write_address] <= write_data;
        end
        if (read_enable) begin
            read_data <= memory[read_address];
        end
    end
endmodule
