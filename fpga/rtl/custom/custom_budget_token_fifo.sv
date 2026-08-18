module custom_budget_token_fifo #(
    parameter integer TOKEN_WIDTH = 32,
    parameter integer COUNT_WIDTH = 17,
    parameter integer DEPTH = 4,
    parameter integer POINTER_WIDTH = (DEPTH <= 2) ? 1 : $clog2(DEPTH),
    parameter integer LEVEL_WIDTH = $clog2(DEPTH + 1)
) (
    input  logic                       clk,
    input  logic                       rst_n,
    input  logic                       clear,

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
    output logic                       m_mandatory,
    output logic [COUNT_WIDTH-1:0]     m_reserve_release,
    output logic [LEVEL_WIDTH-1:0]     level
);

    logic layer_memory [0:DEPTH-1];
    logic [TOKEN_WIDTH-1:0] bits_memory [0:DEPTH-1];
    logic [5:0] length_memory [0:DEPTH-1];
    logic mandatory_memory [0:DEPTH-1];
    logic [COUNT_WIDTH-1:0] reserve_memory [0:DEPTH-1];
    logic [POINTER_WIDTH-1:0] write_pointer, read_pointer;
    logic push, pop;
    localparam logic [LEVEL_WIDTH-1:0] DEPTH_LEVEL = LEVEL_WIDTH'(DEPTH);
    localparam logic [POINTER_WIDTH-1:0] LAST_POINTER =
        POINTER_WIDTH'(DEPTH - 1);

    assign m_valid = level != 0;
    assign s_ready = level < DEPTH_LEVEL;
    assign push = s_valid && s_ready;
    assign pop = m_valid && m_ready;

    always_comb begin
        m_layer = layer_memory[read_pointer];
        m_bits = bits_memory[read_pointer];
        m_length = length_memory[read_pointer];
        m_mandatory = mandatory_memory[read_pointer];
        m_reserve_release = reserve_memory[read_pointer];
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            write_pointer <= 0;
            read_pointer <= 0;
            level <= 0;
        end else if (clear) begin
            write_pointer <= 0;
            read_pointer <= 0;
            level <= 0;
        end else begin
            if (push) begin
                layer_memory[write_pointer] <= s_layer;
                bits_memory[write_pointer] <= s_bits;
                length_memory[write_pointer] <= s_length;
                mandatory_memory[write_pointer] <= s_mandatory;
                reserve_memory[write_pointer] <= s_reserve_release;
                if (write_pointer == LAST_POINTER)
                    write_pointer <= 0;
                else
                    write_pointer <= write_pointer + 1'b1;
            end
            if (pop) begin
                if (read_pointer == LAST_POINTER)
                    read_pointer <= 0;
                else
                    read_pointer <= read_pointer + 1'b1;
            end

            case ({push, pop})
                2'b10: level <= level + 1'b1;
                2'b01: level <= level - 1'b1;
                default: level <= level;
            endcase
        end
    end

endmodule
