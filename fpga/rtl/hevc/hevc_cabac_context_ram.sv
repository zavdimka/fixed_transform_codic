module hevc_cabac_context_ram (
    input  logic       clk,

    input  logic       cfg_write_enable,
    input  logic [7:0] cfg_address,
    input  logic [5:0] cfg_state_index,
    input  logic       cfg_mps,

    input  logic       update_enable,
    input  logic [7:0] update_address,
    input  logic [5:0] update_state_index,
    input  logic       update_mps,

    input  logic       read_enable,
    input  logic [7:0] read_address,
    output logic [5:0] read_state_index,
    output logic       read_mps
);
    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    logic [6:0] memory [0:255];
    logic write_enable;
    logic [7:0] write_address;
    logic [6:0] write_data;

    always_comb begin
        write_enable = cfg_write_enable || update_enable;
        write_address = cfg_write_enable ? cfg_address : update_address;
        write_data = cfg_write_enable ?
            {cfg_mps, cfg_state_index} :
            {update_mps, update_state_index};
    end

    // Keep the write and synchronous read ports in separate clocked processes.
    // This is the simple-dual-port template recognized by Efinity EBR inference.
    always_ff @(posedge clk) begin
        if (write_enable)
            memory[write_address] <= write_data;
    end

    always_ff @(posedge clk) begin
        if (read_enable)
            {read_mps, read_state_index} <= memory[read_address];
    end
endmodule
