module hevc_last_sig_bins8 (
    input logic clk, input logic rst_n,
    input logic s_valid, output logic s_ready, input logic [5:0] s_raster_address,
    output logic m_valid, input logic m_ready, output logic m_bin,
    output logic m_bypass, output logic m_axis_y, output logic [2:0] m_context_index,
    output logic m_syntax_last, output logic busy
);
    typedef enum logic [2:0] {IDLE, X_PREFIX, Y_PREFIX, X_SUFFIX, Y_SUFFIX} state_t;
    state_t state;
    logic [2:0] x, y, group_x, group_y, bit_index;
    function automatic logic [2:0] group_index(input logic [2:0] c);
        case (c) 0:group_index=0;1:group_index=1;2:group_index=2;3:group_index=3;
                 4,5:group_index=4;default:group_index=5; endcase
    endfunction
    function automatic logic [2:0] group_minimum(input logic [2:0] g);
        case (g) 4:group_minimum=4;5:group_minimum=6;default:group_minimum=g; endcase
    endfunction
    wire [2:0] active_group = (state == X_PREFIX || state == X_SUFFIX) ? group_x : group_y;
    wire [2:0] active_coordinate = (state == X_PREFIX || state == X_SUFFIX) ? x : y;
    wire [2:0] suffix = active_coordinate - group_minimum(active_group);
    always_comb begin
        s_ready = state == IDLE; busy = state != IDLE; m_valid = 0; m_bin = 0;
        m_bypass = 0; m_axis_y = state == Y_PREFIX || state == Y_SUFFIX;
        m_context_index = 0; m_syntax_last = 0;
        if (state == X_PREFIX || state == Y_PREFIX) begin
            m_valid = (active_group < 5) || (bit_index < active_group);
            m_bin = bit_index < active_group; m_context_index = bit_index;
            if (state == Y_PREFIX && bit_index == active_group &&
                group_x <= 3 && group_y <= 3)
                m_syntax_last = 1;
        end else if (state == X_SUFFIX || state == Y_SUFFIX) begin
            m_valid = active_group > 3; m_bypass = 1; m_bin = suffix[bit_index[1:0]];
            if ((state == Y_SUFFIX && bit_index == 0) ||
                (state == X_SUFFIX && bit_index == 0 && group_y <= 3)) m_syntax_last = 1;
        end
    end
    always_ff @(posedge clk) begin
        if (!rst_n) begin state<=IDLE;x<=0;y<=0;group_x<=0;group_y<=0;bit_index<=0; end
        else case (state)
            IDLE: if (s_valid) begin
                x<=s_raster_address[2:0]; y<=s_raster_address[5:3];
                group_x<=group_index(s_raster_address[2:0]);
                group_y<=group_index(s_raster_address[5:3]); bit_index<=0; state<=X_PREFIX;
            end
            X_PREFIX: if (m_valid && m_ready) begin
                if ((active_group < 5 && bit_index == active_group) ||
                    (active_group == 5 && bit_index + 1'b1 == active_group)) begin
                    bit_index<=0; state<=Y_PREFIX; end
                else bit_index<=bit_index+1'b1;
            end
            Y_PREFIX: if (m_valid && m_ready) begin
                if ((active_group < 5 && bit_index == active_group) ||
                    (active_group == 5 && bit_index + 1'b1 == active_group)) begin
                    if (group_x>3) begin bit_index<=((group_x-2)>>1)-1'b1; state<=X_SUFFIX; end
                    else if (group_y>3) begin bit_index<=((group_y-2)>>1)-1'b1; state<=Y_SUFFIX; end
                    else state<=IDLE;
                end else bit_index<=bit_index+1'b1;
            end
            X_SUFFIX: if (m_valid && m_ready) begin
                if (bit_index==0) begin
                    if (group_y>3) begin bit_index<=((group_y-2)>>1)-1'b1; state<=Y_SUFFIX; end
                    else state<=IDLE;
                end else bit_index<=bit_index-1'b1;
            end
            default: if (m_valid && m_ready) begin
                if (bit_index==0) state<=IDLE; else bit_index<=bit_index-1'b1;
            end
        endcase
    end
endmodule
