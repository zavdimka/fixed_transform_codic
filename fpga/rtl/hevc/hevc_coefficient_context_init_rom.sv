`timescale 1ns/1ps

`ifndef HEVC_COEFFICIENT_CONTEXT_INIT_FILE
`define HEVC_COEFFICIENT_CONTEXT_INIT_FILE \
    "rtl/hevc/hevc_coefficient_context_init.hex"
`endif

module hevc_coefficient_context_init_rom (
    input  logic       clk,
    input  logic       read_enable,
    input  logic [8:0] read_address,
    output logic [7:0] read_value
);
    logic [7:0] memory [0:383];

    initial begin
        $readmemh(`HEVC_COEFFICIENT_CONTEXT_INIT_FILE, memory);
    end

    always_ff @(posedge clk) begin
        if (read_enable) begin
            read_value <= memory[read_address];
        end
    end
endmodule
