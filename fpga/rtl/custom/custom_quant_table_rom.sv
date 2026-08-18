`ifndef CUSTOM_QUANT_DIVISOR_FILE
`define CUSTOM_QUANT_DIVISOR_FILE "../rtl/custom/custom_quant_divisor_pairs.hex"
`endif

`ifndef CUSTOM_QUANT_RECIPROCAL_FILE
`define CUSTOM_QUANT_RECIPROCAL_FILE "../rtl/custom/custom_quant_reciprocal_pairs.hex"
`endif

module custom_quant_table_rom (
    input  logic         clk,
    input  logic         read_enable,
    input  logic [6:0]   read_address,
    output logic [7:0]   divisor_0,
    output logic [7:0]   divisor_1,
    output logic [17:0]  reciprocal_0,
    output logic [17:0]  reciprocal_1
);
    // Address: quality24, chroma, raster coefficient pair index.
    // Pair words keep the even coefficient in the least-significant field.
    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    logic [15:0] divisor_memory [0:127];
    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    logic [35:0] reciprocal_memory [0:127];
    logic [15:0] divisor_word;
    logic [35:0] reciprocal_word;

    initial begin
        $readmemh(`CUSTOM_QUANT_DIVISOR_FILE, divisor_memory);
        $readmemh(`CUSTOM_QUANT_RECIPROCAL_FILE, reciprocal_memory);
    end

    always_ff @(posedge clk) begin
        if (read_enable) begin
            divisor_word <= divisor_memory[read_address];
            reciprocal_word <= reciprocal_memory[read_address];
        end
    end

    assign divisor_0 = divisor_word[7:0];
    assign divisor_1 = divisor_word[15:8];
    assign reciprocal_0 = reciprocal_word[17:0];
    assign reciprocal_1 = reciprocal_word[35:18];
endmodule
