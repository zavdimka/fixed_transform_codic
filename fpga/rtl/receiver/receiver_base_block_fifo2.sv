module receiver_base_block_fifo2 (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        s_valid,
    output logic        s_ready,
    input  logic [6:0]  s_ctu_index,
    input  logic [2:0]  s_block_index,
    input  logic [1:0]  s_plane,
    input  logic [1:0]  s_mode,
    input  logic [7:0]  s_quality,
    input  logic [71:0] s_coefficients,
    output logic        m_valid,
    input  logic        m_ready,
    output logic [6:0]  m_ctu_index,
    output logic [2:0]  m_block_index,
    output logic [1:0]  m_plane,
    output logic [1:0]  m_mode,
    output logic [7:0]  m_quality,
    output logic [71:0] m_coefficients,
    output logic [1:0]  level
);
    logic [93:0] memory [0:1];
    logic read_pointer, write_pointer;
    wire write_fire = s_valid && s_ready;
    wire read_fire = m_valid && m_ready;

    assign s_ready = (level != 2) || read_fire;
    assign m_valid = (level != 0);
    assign {
        m_ctu_index, m_block_index, m_plane, m_mode, m_quality, m_coefficients
    } = memory[read_pointer];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            read_pointer <= 1'b0;
            write_pointer <= 1'b0;
            level <= 2'd0;
        end else begin
            if (write_fire) begin
                memory[write_pointer] <= {
                    s_ctu_index, s_block_index, s_plane, s_mode,
                    s_quality, s_coefficients
                };
                write_pointer <= ~write_pointer;
            end
            if (read_fire)
                read_pointer <= ~read_pointer;
            case ({write_fire, read_fire})
                2'b10: level <= level + 1'b1;
                2'b01: level <= level - 1'b1;
                default: begin end
            endcase
        end
    end
endmodule
