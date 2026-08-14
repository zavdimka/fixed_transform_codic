module hevc_last_sig_bins16 (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       s_valid,
    output logic       s_ready,
    input  logic [7:0] s_raster_address,
    output logic       m_valid,
    input  logic       m_ready,
    output logic       m_bin,
    output logic       m_bypass,
    output logic       m_axis_y,
    output logic [3:0] m_context_index,
    output logic       m_syntax_last,
    output logic       busy
);
    typedef enum logic [2:0] {
        IDLE, X_PREFIX, Y_PREFIX, X_SUFFIX, Y_SUFFIX
    } state_t;
    state_t state;

    logic [3:0] coordinate_x;
    logic [3:0] coordinate_y;
    logic [2:0] group_x;
    logic [2:0] group_y;
    logic [2:0] bit_index;

    function automatic logic [2:0] group_index(input logic [3:0] coordinate);
        case (coordinate)
            4'd0: group_index = 3'd0;
            4'd1: group_index = 3'd1;
            4'd2: group_index = 3'd2;
            4'd3: group_index = 3'd3;
            4'd4, 4'd5: group_index = 3'd4;
            4'd6, 4'd7: group_index = 3'd5;
            4'd8, 4'd9, 4'd10, 4'd11: group_index = 3'd6;
            default: group_index = 3'd7;
        endcase
    endfunction

    function automatic logic [3:0] group_minimum(input logic [2:0] group_value);
        case (group_value)
            3'd4: group_minimum = 4'd4;
            3'd5: group_minimum = 4'd6;
            3'd6: group_minimum = 4'd8;
            3'd7: group_minimum = 4'd12;
            default: group_minimum = {1'b0, group_value};
        endcase
    endfunction

    wire [2:0] active_group = (state == X_PREFIX || state == X_SUFFIX) ?
                              group_x : group_y;
    wire [3:0] active_coordinate = (state == X_PREFIX || state == X_SUFFIX) ?
                                   coordinate_x : coordinate_y;
    wire [3:0] active_suffix = active_coordinate - group_minimum(active_group);
    always_comb begin
        s_ready = (state == IDLE);
        busy = (state != IDLE);
        m_valid = 1'b0;
        m_bin = 1'b0;
        m_bypass = 1'b0;
        m_axis_y = (state == Y_PREFIX || state == Y_SUFFIX);
        m_context_index = 4'd0;
        m_syntax_last = 1'b0;

        if (state == X_PREFIX || state == Y_PREFIX) begin
            m_valid = 1'b1;
            m_bin = (bit_index < active_group);
            m_context_index = 4'd6 + {2'b00, bit_index[2:1]};
            if (state == Y_PREFIX && active_group <= 3'd3 &&
                    bit_index == active_group && group_x <= 3'd3) begin
                m_syntax_last = 1'b1;
            end
        end else if (state == X_SUFFIX || state == Y_SUFFIX) begin
            m_valid = (active_group > 3'd3);
            m_bypass = 1'b1;
            m_bin = active_suffix[bit_index[1:0]];
            if (state == Y_SUFFIX && bit_index == 0) begin
                m_syntax_last = 1'b1;
            end else if (state == X_SUFFIX && bit_index == 0 &&
                    group_y <= 3'd3) begin
                m_syntax_last = 1'b1;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            coordinate_x <= '0;
            coordinate_y <= '0;
            group_x <= '0;
            group_y <= '0;
            bit_index <= '0;
        end else begin
            case (state)
                IDLE: begin
                    if (s_valid) begin
                        coordinate_x <= s_raster_address[3:0];
                        coordinate_y <= s_raster_address[7:4];
                        group_x <= group_index(s_raster_address[3:0]);
                        group_y <= group_index(s_raster_address[7:4]);
                        bit_index <= 3'd0;
                        state <= X_PREFIX;
                    end
                end
                X_PREFIX: begin
                    if (m_valid && m_ready) begin
                        if ((active_group == 3'd7 && bit_index == 3'd6) ||
                                (active_group < 3'd7 && bit_index == active_group)) begin
                            bit_index <= 3'd0;
                            state <= Y_PREFIX;
                        end else begin
                            bit_index <= bit_index + 1'b1;
                        end
                    end
                end
                Y_PREFIX: begin
                    if (m_valid && m_ready) begin
                        if ((active_group == 3'd7 && bit_index == 3'd6) ||
                                (active_group < 3'd7 && bit_index == active_group)) begin
                            if (group_x > 3'd3) begin
                                bit_index <= ((group_x - 3'd2) >> 1) - 1'b1;
                                state <= X_SUFFIX;
                            end else if (group_y > 3'd3) begin
                                bit_index <= ((group_y - 3'd2) >> 1) - 1'b1;
                                state <= Y_SUFFIX;
                            end else begin
                                state <= IDLE;
                            end
                        end else begin
                            bit_index <= bit_index + 1'b1;
                        end
                    end
                end
                X_SUFFIX: begin
                    if (m_valid && m_ready) begin
                        if (bit_index == 0) begin
                            if (group_y > 3'd3) begin
                                bit_index <= ((group_y - 3'd2) >> 1) - 1'b1;
                                state <= Y_SUFFIX;
                            end else begin
                                state <= IDLE;
                            end
                        end else begin
                            bit_index <= bit_index - 1'b1;
                        end
                    end
                end
                default: begin
                    if (m_valid && m_ready) begin
                        if (bit_index == 0) begin
                            state <= IDLE;
                        end else begin
                            bit_index <= bit_index - 1'b1;
                        end
                    end
                end
            endcase
        end
    end
endmodule
