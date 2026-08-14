`ifndef HEVC_PARAMETER_SET_FILE
`define HEVC_PARAMETER_SET_FILE "rtl/hevc/hevc_parameter_sets.hex"
`endif

module hevc_parameter_set_rom (
    input  logic       clk,
    input  logic [5:0] address,
    output logic [7:0] data
);
    (* ram_style = "block" *) logic [7:0] memory [0:58];

    initial begin
        $readmemh(`HEVC_PARAMETER_SET_FILE, memory);
    end

    always_ff @(posedge clk) begin
        data <= memory[address];
    end
endmodule
