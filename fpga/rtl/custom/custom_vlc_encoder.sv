module custom_vlc_encoder #(
    parameter integer TOKEN_WIDTH = 32
) (
    input  logic                       clk,
    input  logic                       rst_n,
    input  logic                       clear_error,

    input  logic                       s_valid,
    output logic                       s_ready,
    input  logic                       s_table_class,
    input  logic                       s_table_id,
    input  logic [7:0]                 s_symbol,
    input  logic [10:0]                s_amplitude,
    input  logic [3:0]                 s_amplitude_length,

    output logic                       m_valid,
    input  logic                       m_ready,
    output logic [TOKEN_WIDTH-1:0]     m_bits,
    output logic [5:0]                 m_length,
    output logic                       input_error,
    output logic                       busy
);

    typedef enum logic [1:0] {
        WAIT_INPUT,
        CHECK_ENTRY,
        ALIGN_TOKEN
    } state_t;

    localparam logic [5:0] MAX_TOKEN_BITS = 6'(TOKEN_WIDTH);

    state_t state;
    logic rom_read_enable;
    logic [21:0] rom_data;
    logic captured_class;
    logic [7:0] captured_symbol;
    logic [10:0] captured_amplitude;
    logic [3:0] captured_amplitude_length;
    logic [31:0] combined_right;
    logic [5:0] combined_length;
    logic syntax_valid;
    logic [4:0] huffman_length;
    logic [15:0] huffman_code;
    logic [10:0] amplitude_mask;

    assign s_ready = (state == WAIT_INPUT) && (!m_valid || m_ready);
    assign busy = (state != WAIT_INPUT) || m_valid;
    assign rom_read_enable = s_valid && s_ready;
    assign huffman_length = rom_data[20:16];
    assign huffman_code = rom_data[15:0];
    assign amplitude_mask = 11'h7ff >> (4'd11 - captured_amplitude_length);

    always_comb begin
        syntax_valid = 1'b0;
        if (!captured_class) begin
            syntax_valid = (captured_symbol[7:4] == 0)
                        && (captured_symbol[3:0] <= 11)
                        && (captured_amplitude_length == captured_symbol[3:0]);
        end else if ((captured_symbol == 8'h00) || (captured_symbol == 8'hf0)) begin
            syntax_valid = captured_amplitude_length == 0;
        end else begin
            syntax_valid = (captured_symbol[3:0] != 0)
                        && (captured_symbol[3:0] <= 10)
                        && (captured_amplitude_length == captured_symbol[3:0]);
        end
    end

    custom_vlc_rom table_rom (
        .clk(clk),
        .read_enable(rom_read_enable),
        .table_class(s_table_class),
        .table_id(s_table_id),
        .symbol(s_symbol),
        .read_data(rom_data)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= WAIT_INPUT;
            captured_class <= 1'b0;
            captured_symbol <= '0;
            captured_amplitude <= '0;
            captured_amplitude_length <= '0;
            combined_right <= '0;
            combined_length <= '0;
            m_valid <= 1'b0;
            m_bits <= '0;
            m_length <= '0;
            input_error <= 1'b0;
        end else begin
            if (clear_error)
                input_error <= 1'b0;
            if (m_valid && m_ready)
                m_valid <= 1'b0;

            case (state)
                WAIT_INPUT: begin
                    if (s_valid && s_ready) begin
                        captured_class <= s_table_class;
                        captured_symbol <= s_symbol;
                        captured_amplitude <= s_amplitude;
                        captured_amplitude_length <= s_amplitude_length;
                        state <= CHECK_ENTRY;
                    end
                end

                CHECK_ENTRY: begin
                    if (rom_data[21] && syntax_valid
                            && ({1'b0, huffman_length}
                                + {2'b0, captured_amplitude_length}
                                <= MAX_TOKEN_BITS)) begin
                        combined_right <= ({16'b0, huffman_code}
                                           << captured_amplitude_length)
                                        | {{21{1'b0}},
                                           (captured_amplitude & amplitude_mask)};
                        combined_length <= {1'b0, huffman_length}
                                         + {2'b0, captured_amplitude_length};
                        state <= ALIGN_TOKEN;
                    end else begin
                        input_error <= 1'b1;
                        state <= WAIT_INPUT;
                    end
                end

                ALIGN_TOKEN: begin
                    m_valid <= 1'b1;
                    m_bits <= combined_right
                           << (MAX_TOKEN_BITS - combined_length);
                    m_length <= combined_length;
                    state <= WAIT_INPUT;
                end

                default: state <= WAIT_INPUT;
            endcase
        end
    end

endmodule
