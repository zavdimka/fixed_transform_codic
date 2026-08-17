`ifndef CUSTOM_VLC_DC_TABLE_FILE
`define CUSTOM_VLC_DC_TABLE_FILE "../rtl/custom/custom_vlc_dc_table.hex"
`endif

`ifndef CUSTOM_VLC_AC_TABLE_FILE
`define CUSTOM_VLC_AC_TABLE_FILE "../rtl/custom/custom_vlc_ac_table.hex"
`endif

module custom_vlc_rom (
    input  logic        clk,
    input  logic        read_enable,
    input  logic        table_class,
    input  logic        table_id,
    input  logic [7:0]  symbol,
    output logic [21:0] read_data
);

    // Word format: valid[21], code_length[20:16], right-aligned code[15:0].
    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    logic [21:0] dc_memory [0:31];
    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    logic [21:0] ac_memory [0:511];

    initial begin
        $readmemh(`CUSTOM_VLC_DC_TABLE_FILE, dc_memory);
        $readmemh(`CUSTOM_VLC_AC_TABLE_FILE, ac_memory);
    end

    always_ff @(posedge clk) begin
        if (read_enable) begin
            if (table_class)
                read_data <= ac_memory[{table_id, symbol}];
            else
                read_data <= dc_memory[{table_id, symbol[3:0]}];
        end
    end

endmodule

