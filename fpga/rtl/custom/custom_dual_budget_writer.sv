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
    logic [COUNT_WIDTH:0] reserved_after_ext;
    logic [COUNT_WIDTH:0] required_bits_ext;
    logic token_metadata_valid;
    logic token_fits;
    logic output_slot_available;
    logic accept_input;

    always_comb begin
        output_slot_available = !m_valid || m_ready;
        token_metadata_valid = (s_reserve_release <= reserved_bits[s_layer])
                            && (s_mandatory || (s_reserve_release == 0))
                            && (s_length <= MAX_TOKEN_BITS);
        reserved_after_ext = {1'b0, reserved_bits[s_layer]}
                           - {1'b0, s_reserve_release};
        required_bits_ext = {1'b0, used_bits[s_layer]}
                          + {{(COUNT_WIDTH-5){1'b0}}, s_length}
                          + reserved_after_ext;
        token_fits = token_metadata_valid
                  && (required_bits_ext <= {1'b0, limit_bits[s_layer]});
        s_ready = busy && output_slot_available;
        start_ready = !busy && !m_valid;
        finish_ready = busy && !m_valid && !s_valid;
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
            end else if (finish_valid && finish_ready) begin
                busy <= 1'b0;
                if ((reserved_bits[0] != 0) || (reserved_bits[1] != 0))
                    fatal_error <= 1'b1;
            end else if (accept_input) begin
                if (!token_metadata_valid) begin
                    fatal_error <= 1'b1;
                end else if (token_fits) begin
                    used_bits[s_layer] <= used_bits[s_layer]
                                             + {{(COUNT_WIDTH-6){1'b0}}, s_length};
                    reserved_bits[s_layer] <= reserved_after_ext[COUNT_WIDTH-1:0];
                    if (s_length != 0) begin
                        m_valid <= 1'b1;
                        m_layer <= s_layer;
                        m_bits <= s_bits;
                        m_length <= s_length;
                    end
                end else if (s_mandatory) begin
                    fatal_error <= 1'b1;
                end else begin
                    drop_pulse <= 1'b1;
                    drop_layer <= s_layer;
                end
            end
        end
    end

endmodule
