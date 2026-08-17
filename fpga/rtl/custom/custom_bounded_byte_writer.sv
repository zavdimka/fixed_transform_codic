module custom_bounded_byte_writer #(
    parameter integer COUNT_WIDTH = 17,
    parameter integer TOKEN_WIDTH = 32,
    parameter integer BYTE_COUNT_WIDTH = 13
) (
    input  logic                          clk,
    input  logic                          rst_n,

    input  logic                          start_valid,
    output logic                          start_ready,
    input  logic [COUNT_WIDTH-1:0]        base_limit_bits,
    input  logic [COUNT_WIDTH-1:0]        enhancement_limit_bits,
    input  logic [COUNT_WIDTH-1:0]        base_reserved_bits,
    input  logic [COUNT_WIDTH-1:0]        enhancement_reserved_bits,

    input  logic                          finish_valid,
    output logic                          finish_ready,
    output logic                          finish_done,

    input  logic                          s_valid,
    output logic                          s_ready,
    input  logic                          s_layer,
    input  logic [TOKEN_WIDTH-1:0]        s_bits,
    input  logic [5:0]                    s_length,
    input  logic                          s_mandatory,
    input  logic [COUNT_WIDTH-1:0]        s_reserve_release,

    output logic                          m_valid,
    input  logic                          m_ready,
    output logic                          m_layer,
    output logic [7:0]                    m_byte,

    output logic                          drop_pulse,
    output logic                          drop_layer,
    output logic                          fatal_error,
    output logic                          busy,
    output logic [COUNT_WIDTH-1:0]        base_used_bits,
    output logic [COUNT_WIDTH-1:0]        enhancement_used_bits,
    output logic [BYTE_COUNT_WIDTH-1:0]   base_byte_count,
    output logic [BYTE_COUNT_WIDTH-1:0]   enhancement_byte_count
);

    typedef enum logic [1:0] {
        IDLE,
        RUN,
        FINISH_PACKER,
        WAIT_PACKER
    } state_t;

    state_t state;
    logic guard_start_ready, guard_finish_ready, guard_busy;
    logic guard_m_valid, guard_m_ready, guard_m_layer;
    logic [TOKEN_WIDTH-1:0] guard_m_bits;
    logic [5:0] guard_m_length;
    logic guard_fatal_error;
    logic [COUNT_WIDTH-1:0] unused_base_reserve;
    logic [COUNT_WIDTH-1:0] unused_enhancement_reserve;
    logic packer_start_ready, packer_finish_ready, packer_finish_done;
    logic packer_s_ready, packer_busy, packer_input_error;
    logic guard_s_ready_internal;

    assign start_ready = (state == IDLE) && guard_start_ready && packer_start_ready;
    assign finish_ready = (state == RUN) && guard_finish_ready;
    assign s_ready = (state == RUN) && !finish_valid && guard_s_ready_internal;
    assign busy = (state != IDLE) || guard_busy || packer_busy;
    assign fatal_error = guard_fatal_error || packer_input_error;
    assign guard_m_ready = packer_s_ready;

    custom_dual_budget_writer #(
        .COUNT_WIDTH(COUNT_WIDTH),
        .TOKEN_WIDTH(TOKEN_WIDTH)
    ) guard (
        .clk(clk),
        .rst_n(rst_n),
        .start_valid(start_valid && (state == IDLE) && packer_start_ready),
        .start_ready(guard_start_ready),
        .base_limit_bits(base_limit_bits),
        .enhancement_limit_bits(enhancement_limit_bits),
        .base_reserved_bits(base_reserved_bits),
        .enhancement_reserved_bits(enhancement_reserved_bits),
        .finish_valid(finish_valid && finish_ready),
        .finish_ready(guard_finish_ready),
        .s_valid(s_valid && (state == RUN) && !finish_valid),
        .s_ready(guard_s_ready_internal),
        .s_layer(s_layer),
        .s_bits(s_bits),
        .s_length(s_length),
        .s_mandatory(s_mandatory),
        .s_reserve_release(s_reserve_release),
        .m_valid(guard_m_valid),
        .m_ready(guard_m_ready),
        .m_layer(guard_m_layer),
        .m_bits(guard_m_bits),
        .m_length(guard_m_length),
        .drop_pulse(drop_pulse),
        .drop_layer(drop_layer),
        .fatal_error(guard_fatal_error),
        .busy(guard_busy),
        .base_used_bits(base_used_bits),
        .enhancement_used_bits(enhancement_used_bits),
        .base_remaining_reserve(unused_base_reserve),
        .enhancement_remaining_reserve(unused_enhancement_reserve)
    );

    custom_token_byte_packer #(
        .TOKEN_WIDTH(TOKEN_WIDTH),
        .BYTE_COUNT_WIDTH(BYTE_COUNT_WIDTH)
    ) packer (
        .clk(clk),
        .rst_n(rst_n),
        .start_valid(start_valid && (state == IDLE) && guard_start_ready),
        .start_ready(packer_start_ready),
        .finish_valid(state == FINISH_PACKER),
        .finish_ready(packer_finish_ready),
        .finish_done(packer_finish_done),
        .s_valid(guard_m_valid),
        .s_ready(packer_s_ready),
        .s_layer(guard_m_layer),
        .s_bits(guard_m_bits),
        .s_length(guard_m_length),
        .m_valid(m_valid),
        .m_ready(m_ready),
        .m_layer(m_layer),
        .m_byte(m_byte),
        .input_error(packer_input_error),
        .busy(packer_busy),
        .base_byte_count(base_byte_count),
        .enhancement_byte_count(enhancement_byte_count)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            finish_done <= 1'b0;
        end else begin
            finish_done <= 1'b0;
            case (state)
                IDLE: begin
                    if (start_valid && start_ready)
                        state <= RUN;
                end
                RUN: begin
                    if (finish_valid && finish_ready)
                        state <= FINISH_PACKER;
                end
                FINISH_PACKER: begin
                    if (packer_finish_ready)
                        state <= WAIT_PACKER;
                end
                WAIT_PACKER: begin
                    if (packer_finish_done) begin
                        state <= IDLE;
                        finish_done <= 1'b1;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end

endmodule
