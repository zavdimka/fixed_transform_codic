module hevc_cabac_bin_step #(
    parameter bit OUTPUT_REGISTER = 1'b1,
    parameter bit SPLIT_LPS = 1'b0,
    parameter bit SPLIT_MPS = 1'b0,
    parameter bit PREDECODED_LPS = 1'b0
) (
    // The plain combinational specialization has no clocked state.
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic        clk,
    input  logic        rst_n,
    /* verilator lint_on UNUSEDSIGNAL */

    input  logic        s_valid,
    output logic        s_ready,
    input  logic        s_bin,
    input  logic        s_bypass,
    input  logic [31:0] s_low,
    input  logic [8:0]  s_range,
    input  logic [5:0]  s_state_index,
    input  logic        s_mps,
    input  logic [31:0] s_lps_row,

    output logic        m_valid,
    input  logic        m_ready,
    output logic [31:0] m_low,
    output logic [8:0]  m_range,
    output logic [5:0]  m_state_index,
    output logic        m_mps,
    output logic [2:0]  m_renorm_bits
);
    logic [31:0] lps_row;
    logic [7:0] range_lps;
    logic [8:0] range_mps;
    logic mps_renorm;
    logic [2:0] lps_shift;
    logic [8:0] normalized_lps;
    // These results belong to the mutually exclusive registered/plain
    // implementations and are optimized away by the split-LPS specialization.
    /* verilator lint_off UNUSEDSIGNAL */
    logic [31:0] computed_low;
    logic [8:0] computed_range;
    logic [5:0] computed_state_index;
    logic computed_mps;
    logic [2:0] computed_renorm_bits;
    /* verilator lint_on UNUSEDSIGNAL */

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
                6'd63: lps_lookup = {8'd2, 8'd2, 8'd2, 8'd2};
                default: lps_lookup = 32'd0;
            endcase
        end
    endfunction

    function automatic logic [5:0] lps_transition(input logic [5:0] state_index);
        begin
            case (state_index)
                6'd0: lps_transition = 6'd0;
                6'd1: lps_transition = 6'd0;
                6'd2: lps_transition = 6'd1;
                6'd3: lps_transition = 6'd2;
                6'd4: lps_transition = 6'd2;
                6'd5: lps_transition = 6'd4;
                6'd6: lps_transition = 6'd4;
                6'd7: lps_transition = 6'd5;
                6'd8: lps_transition = 6'd6;
                6'd9: lps_transition = 6'd7;
                6'd10: lps_transition = 6'd8;
                6'd11: lps_transition = 6'd9;
                6'd12: lps_transition = 6'd9;
                6'd13: lps_transition = 6'd11;
                6'd14: lps_transition = 6'd11;
                6'd15: lps_transition = 6'd12;
                6'd16: lps_transition = 6'd13;
                6'd17: lps_transition = 6'd13;
                6'd18: lps_transition = 6'd15;
                6'd19: lps_transition = 6'd15;
                6'd20: lps_transition = 6'd16;
                6'd21: lps_transition = 6'd16;
                6'd22: lps_transition = 6'd18;
                6'd23: lps_transition = 6'd18;
                6'd24: lps_transition = 6'd19;
                6'd25: lps_transition = 6'd19;
                6'd26: lps_transition = 6'd21;
                6'd27: lps_transition = 6'd21;
                6'd28: lps_transition = 6'd22;
                6'd29: lps_transition = 6'd22;
                6'd30: lps_transition = 6'd23;
                6'd31: lps_transition = 6'd24;
                6'd32: lps_transition = 6'd24;
                6'd33: lps_transition = 6'd25;
                6'd34: lps_transition = 6'd26;
                6'd35: lps_transition = 6'd26;
                6'd36: lps_transition = 6'd27;
                6'd37: lps_transition = 6'd27;
                6'd38: lps_transition = 6'd28;
                6'd39: lps_transition = 6'd29;
                6'd40: lps_transition = 6'd29;
                6'd41: lps_transition = 6'd30;
                6'd42: lps_transition = 6'd30;
                6'd43: lps_transition = 6'd30;
                6'd44: lps_transition = 6'd31;
                6'd45: lps_transition = 6'd32;
                6'd46: lps_transition = 6'd32;
                6'd47: lps_transition = 6'd33;
                6'd48: lps_transition = 6'd33;
                6'd49: lps_transition = 6'd33;
                6'd50: lps_transition = 6'd34;
                6'd51: lps_transition = 6'd34;
                6'd52: lps_transition = 6'd35;
                6'd53: lps_transition = 6'd35;
                6'd54: lps_transition = 6'd35;
                6'd55: lps_transition = 6'd36;
                6'd56: lps_transition = 6'd36;
                6'd57: lps_transition = 6'd36;
                6'd58: lps_transition = 6'd37;
                6'd59: lps_transition = 6'd37;
                6'd60: lps_transition = 6'd37;
                6'd61: lps_transition = 6'd38;
                6'd62: lps_transition = 6'd38;
                6'd63: lps_transition = 6'd63;
                default: lps_transition = 6'd0;
            endcase
        end
    endfunction

    always_comb begin
        lps_row = PREDECODED_LPS ? s_lps_row : lps_lookup(s_state_index);
        case (s_range[7:6])
            2'd0: range_lps = lps_row[7:0];
            2'd1: range_lps = lps_row[15:8];
            2'd2: range_lps = lps_row[23:16];
            default: range_lps = lps_row[31:24];
        endcase
        range_mps = s_range - {1'b0, range_lps};
        // A normalized CABAC range is 256..510. Therefore
        // (range - range_lps) < 256 is exactly the borrow from the low-byte
        // subtraction. Keep the renormalization control off the longer
        // nine-bit range subtraction path.
        mps_renorm = s_range[7:0] < range_lps;

        lps_shift = 3'd0;
        normalized_lps = {1'b0, range_lps};
        if (normalized_lps < 9'd256) begin
            normalized_lps = normalized_lps << 1;
            lps_shift = lps_shift + 1'b1;
        end
        if (normalized_lps < 9'd256) begin
            normalized_lps = normalized_lps << 1;
            lps_shift = lps_shift + 1'b1;
        end
        if (normalized_lps < 9'd256) begin
            normalized_lps = normalized_lps << 1;
            lps_shift = lps_shift + 1'b1;
        end
        if (normalized_lps < 9'd256) begin
            normalized_lps = normalized_lps << 1;
            lps_shift = lps_shift + 1'b1;
        end
        if (normalized_lps < 9'd256) begin
            normalized_lps = normalized_lps << 1;
            lps_shift = lps_shift + 1'b1;
        end
        if (normalized_lps < 9'd256) begin
            normalized_lps = normalized_lps << 1;
            lps_shift = lps_shift + 1'b1;
        end
        if (normalized_lps < 9'd256) begin
            normalized_lps = normalized_lps << 1;
            lps_shift = lps_shift + 1'b1;
        end

        if (s_bypass) begin
            computed_low = (s_low << 1) +
                (s_bin ? {23'd0, s_range} : 32'd0);
            computed_range = s_range;
            computed_state_index = s_state_index;
            computed_mps = s_mps;
            computed_renorm_bits = 3'd1;
        end else if (s_bin == s_mps) begin
            computed_low = mps_renorm ?
                (s_low << 1) : s_low;
            computed_range = mps_renorm ?
                (range_mps << 1) : range_mps;
            computed_state_index = (s_state_index < 6'd62) ?
                s_state_index + 1'b1 : s_state_index;
            computed_mps = s_mps;
            computed_renorm_bits =
                mps_renorm ? 3'd1 : 3'd0;
        end else begin
            computed_low = (s_low + {23'd0, range_mps}) << lps_shift;
            computed_range = normalized_lps;
            computed_state_index = lps_transition(s_state_index);
            computed_mps = s_mps ^ (s_state_index == 6'd0);
            computed_renorm_bits = lps_shift;
        end
    end

    generate
        if (SPLIT_LPS || SPLIT_MPS) begin : g_split_regular
            logic input_is_lps;
            logic input_needs_register;
            logic accept_registered;
            logic        pending_valid;
            logic        pending_is_lps;
            logic [31:0] pending_low_register;
            logic [8:0]  pending_range_mps_register;
            logic [2:0]  pending_shift_register;
            logic [8:0]  pending_range_register;
            logic [5:0]  pending_state_index_register;
            logic        pending_mps_register;

            always_comb begin
                input_is_lps = !s_bypass && (s_bin != s_mps);
                input_needs_register = SPLIT_MPS ?
                    !s_bypass : input_is_lps;

                // Context-coded bins stop after the LPS-table lookup,
                // range subtraction and state update. The low update and
                // renormalization shift run after this register boundary.
                // Bypass bins retain their short combinational path.
                // Keep ready independent of the context value/MPS decision.
                // Capturing an LPS while the output is blocked saves no
                // cycles in the encoder, but it creates a long RAM-to-CE
                // control path through the upstream bin FIFO.
                s_ready = !pending_valid && m_ready;
                accept_registered =
                    s_valid && s_ready && input_needs_register;
                m_valid =
                    pending_valid || (s_valid && !input_needs_register);

                if (pending_valid) begin
                    m_low = pending_is_lps ?
                        ((pending_low_register +
                        {23'd0, pending_range_mps_register}) <<
                        pending_shift_register) :
                        (pending_low_register << pending_shift_register);
                    m_range = pending_range_register;
                    m_state_index = pending_state_index_register;
                    m_mps = pending_mps_register;
                    m_renorm_bits = pending_shift_register;
                end else if (s_bypass) begin
                    m_low = (s_low << 1) +
                        (s_bin ? {23'd0, s_range} : 32'd0);
                    m_range = s_range;
                    m_state_index = s_state_index;
                    m_mps = s_mps;
                    m_renorm_bits = 3'd1;
                end else if (!SPLIT_MPS) begin
                    // Direct MPS path for the LPS-only specialization.
                    m_low = mps_renorm ?
                        (s_low << 1) : s_low;
                    m_range = mps_renorm ?
                        (range_mps << 1) : range_mps;
                    m_state_index = (s_state_index < 6'd62) ?
                        s_state_index + 1'b1 : s_state_index;
                    m_mps = s_mps;
                    m_renorm_bits =
                        mps_renorm ? 3'd1 : 3'd0;
                end else begin
                    // With SPLIT_MPS enabled a non-bypass regular bin is
                    // always captured above.  Constant values here remove
                    // an unreachable context-to-output timing arc.
                    m_low = 32'd0;
                    m_range = 9'd0;
                    m_state_index = 6'd0;
                    m_mps = 1'b0;
                    m_renorm_bits = 3'd0;
                end
            end

            always_ff @(posedge clk) begin
                if (!rst_n) begin
                    pending_valid <= 1'b0;
                    pending_is_lps <= 1'b0;
                    pending_low_register <= 32'd0;
                    pending_range_mps_register <= 9'd0;
                    pending_shift_register <= 3'd0;
                    pending_range_register <= 9'd0;
                    pending_state_index_register <= 6'd0;
                    pending_mps_register <= 1'b0;
                end else begin
                    if (pending_valid && m_ready) begin
                        pending_valid <= 1'b0;
                    end
                    if (accept_registered) begin
                        pending_valid <= 1'b1;
                        pending_is_lps <= input_is_lps;
                        pending_low_register <= s_low;
                        pending_range_mps_register <= range_mps;
                        if (input_is_lps) begin
                            pending_shift_register <= lps_shift;
                            pending_range_register <= normalized_lps;
                            pending_state_index_register <=
                                lps_transition(s_state_index);
                            pending_mps_register <=
                                s_mps ^ (s_state_index == 6'd0);
                        end else begin
                            pending_shift_register <=
                                mps_renorm ? 3'd1 : 3'd0;
                            pending_range_register <=
                                mps_renorm ?
                                (range_mps << 1) : range_mps;
                            pending_state_index_register <=
                                (s_state_index < 6'd62) ?
                                s_state_index + 1'b1 : s_state_index;
                            pending_mps_register <= s_mps;
                        end
                    end
                end
            end
        end else if (OUTPUT_REGISTER) begin : g_registered_output
            always_comb begin
                s_ready = !m_valid || m_ready;
            end

            always_ff @(posedge clk) begin
                if (!rst_n) begin
                    m_valid <= 1'b0;
                    m_low <= 32'd0;
                    m_range <= 9'd510;
                    m_state_index <= 6'd0;
                    m_mps <= 1'b0;
                    m_renorm_bits <= 3'd0;
                end else if (s_ready) begin
                    m_valid <= s_valid;
                    if (s_valid) begin
                        m_low <= computed_low;
                        m_range <= computed_range;
                        m_state_index <= computed_state_index;
                        m_mps <= computed_mps;
                        m_renorm_bits <= computed_renorm_bits;
                    end
                end
            end
        end else begin : g_combinational_output
            always_comb begin
                s_ready = m_ready;
                m_valid = s_valid;
                m_low = computed_low;
                m_range = computed_range;
                m_state_index = computed_state_index;
                m_mps = computed_mps;
                m_renorm_bits = computed_renorm_bits;
            end
        end
    endgenerate
endmodule
