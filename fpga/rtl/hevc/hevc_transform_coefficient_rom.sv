`ifndef HEVC_TRANSFORM_COEFFICIENT_FILE
`define HEVC_TRANSFORM_COEFFICIENT_FILE \
    "../rtl/hevc/hevc_transform_coefficients.hex"
`endif

module hevc_transform_coefficient_rom (
    input  logic         clk,
    input  logic         read_enable,
    input  logic [5:0]   read_address,
    output logic [127:0] read_data
);
    // 0..15: 16x16 rows, 16..31: 16x16 columns,
    // 32..39: 8x8 rows, 40..47: 8x8 columns.
    // The 8x8 vectors occupy read_data[63:0].
    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    logic [127:0] memory [0:47];

    initial begin
        $readmemh(`HEVC_TRANSFORM_COEFFICIENT_FILE, memory);
    end

    always_ff @(posedge clk) begin
        if (read_enable)
            read_data <= memory[read_address];
    end
endmodule
