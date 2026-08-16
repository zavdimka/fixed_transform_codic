module hevc_coefficient_replay_store #(
    parameter integer ADDRESS_WIDTH = 8
) (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               clear,
    input  logic               write_enable,
    input  logic [ADDRESS_WIDTH-1:0] write_address,
    input  logic signed [15:0] write_data,
    input  logic               block_complete,
    input  logic               block_nonzero,
    output logic               m_valid,
    input  logic               m_ready,
    output logic [ADDRESS_WIDTH-1:0] m_address,
    output logic signed [15:0] m_data,
    output logic               m_block_last,
    output logic               finished
);
    localparam logic [ADDRESS_WIDTH-1:0] LAST_ADDRESS = {ADDRESS_WIDTH{1'b1}};
    logic signed [15:0] memory [0:(1 << ADDRESS_WIDTH)-1];
    logic replay_active;
    logic [ADDRESS_WIDTH-1:0] replay_address;

    wire output_fire = m_valid && m_ready;
    wire replay_issue = replay_active && (!m_valid || m_ready);

    always_ff @(posedge clk) begin
        if (write_enable)
            memory[write_address] <= write_data;

        if (!rst_n) begin
            replay_active <= 1'b0;
            replay_address <= '0;
            m_valid <= 1'b0;
            m_address <= '0;
            m_data <= '0;
            m_block_last <= 1'b0;
            finished <= 1'b0;
        end else if (clear) begin
            replay_active <= 1'b0;
            replay_address <= '0;
            m_valid <= 1'b0;
            m_address <= '0;
            m_block_last <= 1'b0;
            finished <= 1'b0;
        end else begin
            if (output_fire) begin
                m_valid <= 1'b0;
                if (m_block_last)
                    finished <= 1'b1;
            end

            if (block_complete) begin
                replay_address <= '0;
                if (block_nonzero)
                    replay_active <= 1'b1;
                else
                    finished <= 1'b1;
            end

            if (replay_issue) begin
                m_valid <= 1'b1;
                m_address <= replay_address;
                m_data <= memory[replay_address];
                m_block_last <= replay_address == LAST_ADDRESS;
                if (replay_address == LAST_ADDRESS)
                    replay_active <= 1'b0;
                else
                    replay_address <= replay_address + 1'b1;
            end
        end
    end
endmodule
