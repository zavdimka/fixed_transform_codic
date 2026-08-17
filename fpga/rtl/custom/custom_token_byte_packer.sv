module custom_token_byte_packer #(
    parameter integer TOKEN_WIDTH = 32,
    parameter integer BYTE_COUNT_WIDTH = 13
) (
    input  logic                          clk,
    input  logic                          rst_n,

    input  logic                          start_valid,
    output logic                          start_ready,
    input  logic                          finish_valid,
    output logic                          finish_ready,
    output logic                          finish_done,

    input  logic                          s_valid,
    output logic                          s_ready,
    input  logic                          s_layer,
    input  logic [TOKEN_WIDTH-1:0]        s_bits,
    input  logic [5:0]                    s_length,

    output logic                          m_valid,
    input  logic                          m_ready,
    output logic                          m_layer,
    output logic [7:0]                    m_byte,

    output logic                          input_error,
    output logic                          busy,
    output logic [BYTE_COUNT_WIDTH-1:0]   base_byte_count,
    output logic [BYTE_COUNT_WIDTH-1:0]   enhancement_byte_count
);

    typedef enum logic [2:0] {
        IDLE,
        RUN,
        FLUSH_BASE,
        FLUSH_ENHANCEMENT,
        WAIT_LAST
    } state_t;

    localparam logic [5:0] MAX_TOKEN_BITS = 6'(TOKEN_WIDTH);

    state_t state;
    logic [TOKEN_WIDTH-1:0] token_shift;
    logic [5:0] token_remaining;
    logic token_layer;
    logic [7:0] partial_byte [0:1];
    logic [2:0] partial_count [0:1];
    logic output_slot_available;
    logic token_active;
    logic token_metadata_valid;
    logic [7:0] completed_byte;

    always_comb begin
        output_slot_available = !m_valid || m_ready;
        token_active = token_remaining != 0;
        token_metadata_valid = (s_length != 0) && (s_length <= MAX_TOKEN_BITS);
        completed_byte = {partial_byte[token_layer][6:0], token_shift[TOKEN_WIDTH-1]};

        start_ready = (state == IDLE) && !m_valid;
        finish_ready = (state == RUN) && !token_active && !s_valid;
        s_ready = (state == RUN) && !token_active;
        busy = state != IDLE;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            token_shift <= '0;
            token_remaining <= '0;
            token_layer <= 1'b0;
            partial_byte[0] <= '0;
            partial_byte[1] <= '0;
            partial_count[0] <= '0;
            partial_count[1] <= '0;
            m_valid <= 1'b0;
            m_layer <= 1'b0;
            m_byte <= '0;
            finish_done <= 1'b0;
            input_error <= 1'b0;
            base_byte_count <= '0;
            enhancement_byte_count <= '0;
        end else begin
            finish_done <= 1'b0;

            if (m_valid && m_ready)
                m_valid <= 1'b0;

            case (state)
                IDLE: begin
                    if (start_valid && start_ready) begin
                        state <= RUN;
                        token_shift <= '0;
                        token_remaining <= '0;
                        partial_byte[0] <= '0;
                        partial_byte[1] <= '0;
                        partial_count[0] <= '0;
                        partial_count[1] <= '0;
                        input_error <= 1'b0;
                        base_byte_count <= '0;
                        enhancement_byte_count <= '0;
                    end
                end

                RUN: begin
                    if (finish_valid && finish_ready) begin
                        state <= FLUSH_BASE;
                    end else if (s_valid && s_ready) begin
                        if (token_metadata_valid) begin
                            token_shift <= s_bits;
                            token_remaining <= s_length;
                            token_layer <= s_layer;
                        end else begin
                            input_error <= 1'b1;
                        end
                    end else if (token_active && output_slot_available) begin
                        token_shift <= {token_shift[TOKEN_WIDTH-2:0], 1'b0};
                        token_remaining <= token_remaining - 1'b1;
                        if (partial_count[token_layer] == 3'd7) begin
                            partial_byte[token_layer] <= '0;
                            partial_count[token_layer] <= '0;
                            m_valid <= 1'b1;
                            m_layer <= token_layer;
                            m_byte <= completed_byte;
                            if (token_layer)
                                enhancement_byte_count <= enhancement_byte_count + 1'b1;
                            else
                                base_byte_count <= base_byte_count + 1'b1;
                        end else begin
                            partial_byte[token_layer] <= completed_byte;
                            partial_count[token_layer] <= partial_count[token_layer] + 1'b1;
                        end
                    end
                end

                FLUSH_BASE: begin
                    if (output_slot_available) begin
                        if (partial_count[0] != 0) begin
                            m_valid <= 1'b1;
                            m_layer <= 1'b0;
                            m_byte <= partial_byte[0] << (8 - partial_count[0]);
                            partial_byte[0] <= '0;
                            partial_count[0] <= '0;
                            base_byte_count <= base_byte_count + 1'b1;
                        end
                        state <= FLUSH_ENHANCEMENT;
                    end
                end

                FLUSH_ENHANCEMENT: begin
                    if (output_slot_available) begin
                        if (partial_count[1] != 0) begin
                            m_valid <= 1'b1;
                            m_layer <= 1'b1;
                            m_byte <= partial_byte[1] << (8 - partial_count[1]);
                            partial_byte[1] <= '0;
                            partial_count[1] <= '0;
                            enhancement_byte_count <= enhancement_byte_count + 1'b1;
                        end
                        state <= WAIT_LAST;
                    end
                end

                WAIT_LAST: begin
                    if (!m_valid) begin
                        state <= IDLE;
                        finish_done <= 1'b1;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule

