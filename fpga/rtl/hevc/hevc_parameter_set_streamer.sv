module hevc_parameter_set_streamer (
    input  logic       clk,
    input  logic       rst_n,

    input  logic       start_valid,
    output logic       start_ready,

    output logic       m_valid,
    input  logic       m_ready,
    output logic [7:0] m_data,
    output logic       m_last,

    output logic       busy,
    output logic       done,
    output logic       parameter_error
);
    typedef enum logic [2:0] {
        IDLE,
        START_NAL,
        ROM_WAIT,
        FEED_RBSP,
        WAIT_NAL
    } state_t;

    state_t state;
    logic [1:0] parameter_set_index;
    logic [5:0] rom_address;
    logic [5:0] end_address;
    logic [7:0] rom_data;

    logic       nal_start_valid;
    logic       nal_start_ready;
    logic [5:0] nal_unit_type;
    logic       nal_s_valid;
    logic       nal_s_ready;
    logic       nal_s_last;
    logic       nal_busy;
    logic       nal_parameter_error;

    assign start_ready = (state == IDLE);
    assign busy = (state != IDLE);

    assign nal_start_valid = (state == START_NAL);
    assign nal_unit_type = 6'd32 + {4'd0, parameter_set_index};
    assign nal_s_valid = (state == FEED_RBSP);
    assign nal_s_last = (rom_address == end_address);
    assign parameter_error = nal_parameter_error;

    hevc_parameter_set_rom parameter_set_rom (
        .clk(clk),
        .address(rom_address),
        .data(rom_data)
    );

    hevc_nal_writer nal_writer (
        .clk(clk),
        .rst_n(rst_n),
        .start_valid(nal_start_valid),
        .start_ready(nal_start_ready),
        .nal_unit_type(nal_unit_type),
        .temporal_id_plus1(3'd1),
        .s_valid(nal_s_valid),
        .s_ready(nal_s_ready),
        .s_data(rom_data),
        .s_last(nal_s_last),
        .m_valid(m_valid),
        .m_ready(m_ready),
        .m_data(m_data),
        .m_last(m_last),
        .busy(nal_busy),
        .parameter_error(nal_parameter_error)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            parameter_set_index <= '0;
            rom_address <= '0;
            end_address <= 6'd18;
            done <= 1'b0;
        end else begin
            done <= 1'b0;

            case (state)
                IDLE: if (start_valid) begin
                    parameter_set_index <= 0;
                    rom_address <= 0;
                    end_address <= 6'd18;
                    state <= START_NAL;
                end
                START_NAL: if (nal_start_ready) begin
                    state <= ROM_WAIT;
                end
                ROM_WAIT: begin
                    state <= FEED_RBSP;
                end
                FEED_RBSP: if (nal_s_ready) begin
                    if (rom_address == end_address) begin
                        state <= WAIT_NAL;
                    end else begin
                        rom_address <= rom_address + 1'b1;
                        state <= ROM_WAIT;
                    end
                end
                WAIT_NAL: if (!nal_busy) begin
                    if (parameter_set_index == 2) begin
                        done <= 1'b1;
                        state <= IDLE;
                    end else begin
                        parameter_set_index <= parameter_set_index + 1'b1;
                        if (parameter_set_index == 0) begin
                            rom_address <= 6'd19;
                            end_address <= 6'd53;
                        end else begin
                            rom_address <= 6'd54;
                            end_address <= 6'd58;
                        end
                        state <= START_NAL;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
