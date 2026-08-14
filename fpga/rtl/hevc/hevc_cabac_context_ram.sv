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
    logic [6:0] memory [0:255];

    always_ff @(posedge clk) begin
        if (cfg_write_enable) begin
            memory[cfg_address] <= {cfg_mps, cfg_state_index};
        end else if (update_enable) begin
            memory[update_address] <= {update_mps, update_state_index};
        end

        if (read_enable) begin
            {read_mps, read_state_index} <= memory[read_address];
        end
    end
endmodule
