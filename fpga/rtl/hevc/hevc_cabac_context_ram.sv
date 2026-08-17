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
    output logic       read_mps,
    output logic [31:0] read_lps_row,

    input  logic [5:0] lookup_state_index,
    output logic [31:0] lookup_lps_row
);
    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    logic [38:0] memory [0:255];
    logic write_enable;
    logic [7:0] write_address;
    logic [38:0] write_data;

    function automatic logic [31:0] lps_lookup(input logic [5:0] state_index);
        begin
            case (state_index)
                6'd0: lps_lookup = {8'd240, 8'd208, 8'd176, 8'd128};
                6'd1: lps_lookup = {8'd227, 8'd197, 8'd167, 8'd128};
                6'd2: lps_lookup = {8'd216, 8'd187, 8'd158, 8'd128};
                6'd3: lps_lookup = {8'd205, 8'd178, 8'd150, 8'd123};
                6'd4: lps_lookup = {8'd195, 8'd169, 8'd142, 8'd116};
                6'd5: lps_lookup = {8'd185, 8'd160, 8'd135, 8'd111};
                6'd6: lps_lookup = {8'd175, 8'd152, 8'd128, 8'd105};
                6'd7: lps_lookup = {8'd166, 8'd144, 8'd122, 8'd100};
                6'd8: lps_lookup = {8'd158, 8'd137, 8'd116, 8'd95};
                6'd9: lps_lookup = {8'd150, 8'd130, 8'd110, 8'd90};
                6'd10: lps_lookup = {8'd142, 8'd123, 8'd104, 8'd85};
                6'd11: lps_lookup = {8'd135, 8'd117, 8'd99, 8'd81};
                6'd12: lps_lookup = {8'd128, 8'd111, 8'd94, 8'd77};
                6'd13: lps_lookup = {8'd122, 8'd105, 8'd89, 8'd73};
                6'd14: lps_lookup = {8'd116, 8'd100, 8'd85, 8'd69};
                6'd15: lps_lookup = {8'd110, 8'd95, 8'd80, 8'd66};
                6'd16: lps_lookup = {8'd104, 8'd90, 8'd76, 8'd62};
                6'd17: lps_lookup = {8'd99, 8'd86, 8'd72, 8'd59};
                6'd18: lps_lookup = {8'd94, 8'd81, 8'd69, 8'd56};
                6'd19: lps_lookup = {8'd89, 8'd77, 8'd65, 8'd53};
                6'd20: lps_lookup = {8'd85, 8'd73, 8'd62, 8'd51};
                6'd21: lps_lookup = {8'd80, 8'd69, 8'd59, 8'd48};
                6'd22: lps_lookup = {8'd76, 8'd66, 8'd56, 8'd46};
                6'd23: lps_lookup = {8'd72, 8'd63, 8'd53, 8'd43};
                6'd24: lps_lookup = {8'd69, 8'd59, 8'd50, 8'd41};
                6'd25: lps_lookup = {8'd65, 8'd56, 8'd48, 8'd39};
                6'd26: lps_lookup = {8'd62, 8'd54, 8'd45, 8'd37};
                6'd27: lps_lookup = {8'd59, 8'd51, 8'd43, 8'd35};
                6'd28: lps_lookup = {8'd56, 8'd48, 8'd41, 8'd33};
                6'd29: lps_lookup = {8'd53, 8'd46, 8'd39, 8'd32};
                6'd30: lps_lookup = {8'd50, 8'd43, 8'd37, 8'd30};
                6'd31: lps_lookup = {8'd48, 8'd41, 8'd35, 8'd29};
                6'd32: lps_lookup = {8'd45, 8'd39, 8'd33, 8'd27};
                6'd33: lps_lookup = {8'd43, 8'd37, 8'd31, 8'd26};
                6'd34: lps_lookup = {8'd41, 8'd35, 8'd30, 8'd24};
                6'd35: lps_lookup = {8'd39, 8'd33, 8'd28, 8'd23};
                6'd36: lps_lookup = {8'd37, 8'd32, 8'd27, 8'd22};
                6'd37: lps_lookup = {8'd35, 8'd30, 8'd26, 8'd21};
                6'd38: lps_lookup = {8'd33, 8'd29, 8'd24, 8'd20};
                6'd39: lps_lookup = {8'd31, 8'd27, 8'd23, 8'd19};
                6'd40: lps_lookup = {8'd30, 8'd26, 8'd22, 8'd18};
                6'd41: lps_lookup = {8'd28, 8'd25, 8'd21, 8'd17};
                6'd42: lps_lookup = {8'd27, 8'd23, 8'd20, 8'd16};
                6'd43: lps_lookup = {8'd25, 8'd22, 8'd19, 8'd15};
                6'd44: lps_lookup = {8'd24, 8'd21, 8'd18, 8'd14};
                6'd45: lps_lookup = {8'd23, 8'd20, 8'd17, 8'd14};
                6'd46: lps_lookup = {8'd22, 8'd19, 8'd16, 8'd13};
                6'd47: lps_lookup = {8'd21, 8'd18, 8'd15, 8'd12};
                6'd48: lps_lookup = {8'd20, 8'd17, 8'd14, 8'd12};
                6'd49: lps_lookup = {8'd19, 8'd16, 8'd14, 8'd11};
                6'd50: lps_lookup = {8'd18, 8'd15, 8'd13, 8'd11};
                6'd51: lps_lookup = {8'd17, 8'd15, 8'd12, 8'd10};
                6'd52: lps_lookup = {8'd16, 8'd14, 8'd12, 8'd10};
                6'd53: lps_lookup = {8'd15, 8'd13, 8'd11, 8'd9};
                6'd54: lps_lookup = {8'd14, 8'd12, 8'd11, 8'd9};
                6'd55: lps_lookup = {8'd14, 8'd12, 8'd10, 8'd8};
                6'd56: lps_lookup = {8'd13, 8'd11, 8'd9, 8'd8};
                6'd57: lps_lookup = {8'd12, 8'd11, 8'd9, 8'd7};
                6'd58: lps_lookup = {8'd12, 8'd10, 8'd9, 8'd7};
                6'd59: lps_lookup = {8'd11, 8'd10, 8'd8, 8'd7};
                6'd60: lps_lookup = {8'd11, 8'd9, 8'd8, 8'd6};
                6'd61: lps_lookup = {8'd10, 8'd9, 8'd7, 8'd6};
                6'd62: lps_lookup = {8'd9, 8'd8, 8'd7, 8'd6};
                default: lps_lookup = {8'd2, 8'd2, 8'd2, 8'd2};
            endcase
        end
    endfunction

    assign lookup_lps_row = lps_lookup(lookup_state_index);

    always_comb begin
        write_enable = cfg_write_enable || update_enable;
        write_address = cfg_write_enable ? cfg_address : update_address;
        write_data = cfg_write_enable ?
            {lps_lookup(cfg_state_index), cfg_mps, cfg_state_index} :
            {lookup_lps_row, update_mps, update_state_index};
    end

    // Keep the write and synchronous read ports in separate clocked processes.
    // This is the simple-dual-port template recognized by Efinity EBR inference.
    always_ff @(posedge clk) begin
        if (write_enable)
            memory[write_address] <= write_data;
    end

    always_ff @(posedge clk) begin
        if (read_enable)
            {read_lps_row, read_mps, read_state_index} <=
                memory[read_address];
    end
endmodule
