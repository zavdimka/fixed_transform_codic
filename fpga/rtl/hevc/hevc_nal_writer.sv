module hevc_nal_writer (
    input  logic       clk,
    input  logic       rst_n,

    input  logic       start_valid,
    output logic       start_ready,
    input  logic [5:0] nal_unit_type,
    input  logic [2:0] temporal_id_plus1,

    input  logic       s_valid,
    output logic       s_ready,
    input  logic [7:0] s_data,
    input  logic       s_last,

    output logic       m_valid,
    input  logic       m_ready,
    output logic [7:0] m_data,
    output logic       m_last,

    output logic       busy,
    output logic       parameter_error
);
    typedef enum logic [3:0] {
        IDLE,
        START_CODE_0,
        START_CODE_1,
        START_CODE_2,
        START_CODE_3,
        HEADER_0,
        HEADER_1,
        PAYLOAD
    } state_t;

    state_t state;
    logic [5:0] latched_nal_unit_type;
    logic [2:0] latched_temporal_id_plus1;
    logic [1:0] zero_count;

    wire insert_emulation_prevention = s_valid &&
        (zero_count == 2) && (s_data <= 8'h03);
    wire output_fire = m_valid && m_ready;

    assign start_ready = (state == IDLE);
    assign busy = (state != IDLE);

    always_comb begin
        s_ready = 1'b0;
        m_valid = 1'b0;
        m_data = 8'h00;
        m_last = 1'b0;

        case (state)
            START_CODE_0,
            START_CODE_1,
            START_CODE_2: begin
                m_valid = 1'b1;
                m_data = 8'h00;
            end
            START_CODE_3: begin
                m_valid = 1'b1;
                m_data = 8'h01;
            end
            HEADER_0: begin
                m_valid = 1'b1;
                m_data = {1'b0, latched_nal_unit_type, 1'b0};
            end
            HEADER_1: begin
                m_valid = 1'b1;
                m_data = {5'b00000, latched_temporal_id_plus1};
            end
            PAYLOAD: begin
                m_valid = s_valid;
                if (insert_emulation_prevention) begin
                    m_data = 8'h03;
                end else begin
                    m_data = s_data;
                    m_last = s_last;
                    s_ready = m_ready;
                end
            end
            default: begin
            end
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            latched_nal_unit_type <= '0;
            latched_temporal_id_plus1 <= '0;
            zero_count <= '0;
            parameter_error <= 1'b0;
        end else begin
            parameter_error <= 1'b0;

            case (state)
                IDLE: begin
                    zero_count <= '0;
                    if (start_valid) begin
                        if (temporal_id_plus1 == 0) begin
                            parameter_error <= 1'b1;
                        end else begin
                            latched_nal_unit_type <= nal_unit_type;
                            latched_temporal_id_plus1 <= temporal_id_plus1;
                            state <= START_CODE_0;
                        end
                    end
                end
                START_CODE_0: if (output_fire) state <= START_CODE_1;
                START_CODE_1: if (output_fire) state <= START_CODE_2;
                START_CODE_2: if (output_fire) state <= START_CODE_3;
                START_CODE_3: if (output_fire) state <= HEADER_0;
                HEADER_0: if (output_fire) state <= HEADER_1;
                HEADER_1: if (output_fire) begin
                    zero_count <= '0;
                    state <= PAYLOAD;
                end
                PAYLOAD: if (output_fire) begin
                    if (insert_emulation_prevention) begin
                        zero_count <= '0;
                    end else begin
                        if (s_data == 0) begin
                            if (zero_count != 2)
                                zero_count <= zero_count + 1'b1;
                        end else begin
                            zero_count <= '0;
                        end
                        if (s_last)
                            state <= IDLE;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
