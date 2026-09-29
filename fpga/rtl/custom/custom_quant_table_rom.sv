`ifndef CUSTOM_QUANT_MAGIC_FILE
`define CUSTOM_QUANT_MAGIC_FILE "../rtl/custom/custom_quant_magic_pairs.hex"
`endif

module custom_quant_table_rom (
    input  logic         clk,
    input  logic         read_enable,
    input  logic [6:0]   read_address,
    output logic [7:0]   divisor_0,
    output logic [7:0]   divisor_1,
    output logic [15:0]  multiplier_0,
    output logic [15:0]  multiplier_1,
    output logic [4:0]   shift_0,
    output logic [4:0]   shift_1
);
    // Address: quality24, chroma, raster coefficient pair index.
    // Each 58-bit entry contains both divisors, exact 16-bit reciprocal
    // multipliers and their right shifts.  For every possible rounded
    // 16-bit numerator, (numerator * multiplier) >> shift is exact.
    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    logic [57:0] memory [0:127];
    logic [57:0] word;

    initial begin
        $readmemh(`CUSTOM_QUANT_MAGIC_FILE, memory);
    end

    always_ff @(posedge clk) begin
        if (read_enable)
            word <= memory[read_address];
    end

    assign divisor_0 = word[7:0];
    assign divisor_1 = word[15:8];
    assign multiplier_0 = word[31:16];
    assign multiplier_1 = word[47:32];
    assign shift_0 = word[52:48];
    assign shift_1 = word[57:53];
endmodule
