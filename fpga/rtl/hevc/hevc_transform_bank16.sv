module hevc_transform_bank16 (
    input  logic               clk,
    input  logic               write_enable,
    input  logic [3:0]         write_address,
    input  logic signed [15:0] write_data,
    input  logic               read_enable,
    input  logic [3:0]         read_address,
    output logic signed [15:0] read_data
);
    (* ram_style = "block" *) logic signed [15:0] memory [0:15];

    always_ff @(posedge clk) begin
        if (write_enable)
            memory[write_address] <= write_data;
        if (read_enable)
            read_data <= memory[read_address];
    end
endmodule
