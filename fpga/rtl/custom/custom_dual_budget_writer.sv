module custom_dual_budget_writer #(
    parameter integer COUNT_WIDTH = 17,
    parameter integer TOKEN_WIDTH = 32
) (
    input  logic                       clk,
    input  logic                       rst_n,

    input  logic                       start_valid,
    output logic                       start_ready,
    input  logic [COUNT_WIDTH-1:0]     base_limit_bits,
    input  logic [COUNT_WIDTH-1:0]     enhancement_limit_bits,
    input  logic [COUNT_WIDTH-1:0]     base_reserved_bits,
    input  logic [COUNT_WIDTH-1:0]     enhancement_reserved_bits,

    input  logic                       finish_valid,
    output logic                       finish_ready,

    input  logic                       s_valid,
    output logic                       s_ready,
    input  logic                       s_layer,
    input  logic [TOKEN_WIDTH-1:0]     s_bits,
    input  logic [5:0]                 s_length,
    input  logic                       s_mandatory,
    input  logic [COUNT_WIDTH-1:0]     s_reserve_release,

    output logic                       m_valid,
    input  logic                       m_ready,
    output logic                       m_layer,
    output logic [TOKEN_WIDTH-1:0]     m_bits,
    output logic [5:0]                 m_length,

    output logic                       drop_pulse,
    output logic                       drop_layer,
    output logic                       fatal_error,
    output logic                       busy,
    output logic [COUNT_WIDTH-1:0]     base_used_bits,
    output logic [COUNT_WIDTH-1:0]     enhancement_used_bits,
    output logic [COUNT_WIDTH-1:0]     base_remaining_reserve,
    output logic [COUNT_WIDTH-1:0]     enhancement_remaining_reserve
);

    localparam logic [5:0] MAX_TOKEN_BITS = 6'(TOKEN_WIDTH);

    logic [COUNT_WIDTH-1:0] limit_bits [0:1];
    logic [COUNT_WIDTH-1:0] used_bits [0:1];
    logic [COUNT_WIDTH-1:0] reserved_bits [0:1];
    logic discard_optional [0:1];
    logic analysis_valid;
    logic analysis_layer, analysis_mandatory, analysis_metadata_valid;
    logic analysis_discard_optional;
    logic [TOKEN_WIDTH-1:0] analysis_bits;
    logic [5:0] analysis_length;
    logic [COUNT_WIDTH:0] analysis_reserved_after;
    logic [COUNT_WIDTH:0] analysis_used_after;
    logic [COUNT_WIDTH:0] analysis_limit;
    logic [COUNT_WIDTH:0] analysis_required_bits;
    logic analysis_token_fits;
    logic output_slot_available;
    logic accept_input;

    always_comb begin
        output_slot_available = !m_valid || m_ready;
        analysis_required_bits = analysis_used_after
                               + analysis_reserved_after;
        analysis_token_fits = analysis_metadata_valid
                           && (analysis_required_bits <= analysis_limit);
        s_ready = busy && !analysis_valid;
        start_ready = !busy && !m_valid && !analysis_valid;
        finish_ready = busy && !m_valid && !analysis_valid && !s_valid;
        accept_input = s_valid && s_ready;
        base_used_bits = used_bits[0];
        enhancement_used_bits = used_bits[1];
        base_remaining_reserve = reserved_bits[0];
        enhancement_remaining_reserve = reserved_bits[1];
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy <= 1'b0;
            m_valid <= 1'b0;
            m_layer <= 1'b0;
            m_bits <= '0;
            m_length <= '0;
            drop_pulse <= 1'b0;
            drop_layer <= 1'b0;
            fatal_error <= 1'b0;
            limit_bits[0] <= '0;
            limit_bits[1] <= '0;
            used_bits[0] <= '0;
            used_bits[1] <= '0;
            reserved_bits[0] <= '0;
            reserved_bits[1] <= '0;
            discard_optional[0] <= 1'b0;
            discard_optional[1] <= 1'b0;
            analysis_valid <= 1'b0;
            analysis_layer <= 1'b0;
            analysis_mandatory <= 1'b0;
            analysis_metadata_valid <= 1'b0;
            analysis_discard_optional <= 1'b0;
            analysis_bits <= '0;
            analysis_length <= '0;
            analysis_reserved_after <= '0;
            analysis_used_after <= '0;
            analysis_limit <= '0;
        end else begin
            drop_pulse <= 1'b0;

            if (m_valid && m_ready)
                m_valid <= 1'b0;

            if (start_valid && start_ready) begin
                busy <= 1'b1;
                fatal_error <= (base_reserved_bits > base_limit_bits)
                            || (enhancement_reserved_bits > enhancement_limit_bits);
                limit_bits[0] <= base_limit_bits;
                limit_bits[1] <= enhancement_limit_bits;
                used_bits[0] <= '0;
                used_bits[1] <= '0;
                reserved_bits[0] <= base_reserved_bits;
                reserved_bits[1] <= enhancement_reserved_bits;
                discard_optional[0] <= 1'b0;
                discard_optional[1] <= 1'b0;
                analysis_valid <= 1'b0;
            end else if (finish_valid && finish_ready) begin
                busy <= 1'b0;
                if ((reserved_bits[0] != 0) || (reserved_bits[1] != 0))
                    fatal_error <= 1'b1;
            end else if (analysis_valid && output_slot_available) begin
                analysis_valid <= 1'b0;
                if (!analysis_metadata_valid) begin
                    fatal_error <= 1'b1;
                end else if (!analysis_mandatory
                             && analysis_discard_optional) begin
                    drop_pulse <= 1'b1;
                    drop_layer <= analysis_layer;
                end else if (analysis_token_fits) begin
                    used_bits[analysis_layer] <=
                        analysis_used_after[COUNT_WIDTH-1:0];
                    reserved_bits[analysis_layer] <=
                        analysis_reserved_after[COUNT_WIDTH-1:0];
                    if (analysis_mandatory)
                        discard_optional[analysis_layer] <= 1'b0;
                    if (analysis_length != 0) begin
                        m_valid <= 1'b1;
                        m_layer <= analysis_layer;
                        m_bits <= analysis_bits;
                        m_length <= analysis_length;
                    end
                end else if (analysis_mandatory) begin
                    fatal_error <= 1'b1;
                end else begin
                    drop_pulse <= 1'b1;
                    drop_layer <= analysis_layer;
                    discard_optional[analysis_layer] <= 1'b1;
                end
            end else if (accept_input) begin
                analysis_valid <= 1'b1;
                analysis_layer <= s_layer;
                analysis_mandatory <= s_mandatory;
                analysis_metadata_valid <=
                    (s_reserve_release <= reserved_bits[s_layer])
                    && (s_mandatory || (s_reserve_release == 0))
                    && (s_length <= MAX_TOKEN_BITS);
                analysis_discard_optional <= discard_optional[s_layer];
                analysis_bits <= s_bits;
                analysis_length <= s_length;
                analysis_reserved_after <=
                    {1'b0, reserved_bits[s_layer]}
                    - {1'b0, s_reserve_release};
                analysis_used_after <=
                    {1'b0, used_bits[s_layer]}
                    + {{(COUNT_WIDTH-5){1'b0}}, s_length};
                analysis_limit <= {1'b0, limit_bits[s_layer]};
            end
        end
    end

endmodule
