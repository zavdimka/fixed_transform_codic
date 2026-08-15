module hevc_transform8_core #(
    parameter bit INVERSE = 1'b0
) (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               s_valid,
    output logic               s_ready,
    input  logic signed [15:0] s_data,
    output logic               m_valid,
    input  logic               m_ready,
    output logic signed [15:0] m_data,
    output logic [2:0]         m_x,
    output logic [2:0]         m_y,
    output logic               m_block_last
);
    typedef enum logic [1:0] {LOAD, PASS1, PASS2} state_t;
    state_t state;
    logic signed [15:0] input_memory [0:63];
    logic signed [15:0] intermediate [0:63];
    logic [5:0] load_address;
    logic [2:0] pass1_row, pass1_output;
    logic [2:0] pass2_x, pass2_y;
    logic signed [31:0] engine_sum;
    logic signed [15:0] engine_sample [0:7];
    logic signed [7:0] engine_coefficient [0:7];
    integer k;

    function automatic logic signed [7:0] tc(input logic [2:0] o, input logic [2:0] i);
        case (o)
            3'd0: case (i) 0:tc=64;1:tc=64;2:tc=64;3:tc=64;4:tc=64;5:tc=64;6:tc=64;default:tc=64; endcase
            3'd1: case (i) 0:tc=89;1:tc=75;2:tc=50;3:tc=18;4:tc=-18;5:tc=-50;6:tc=-75;default:tc=-89; endcase
            3'd2: case (i) 0:tc=83;1:tc=36;2:tc=-36;3:tc=-83;4:tc=-83;5:tc=-36;6:tc=36;default:tc=83; endcase
            3'd3: case (i) 0:tc=75;1:tc=-18;2:tc=-89;3:tc=-50;4:tc=50;5:tc=89;6:tc=18;default:tc=-75; endcase
            3'd4: case (i) 0:tc=64;1:tc=-64;2:tc=-64;3:tc=64;4:tc=64;5:tc=-64;6:tc=-64;default:tc=64; endcase
            3'd5: case (i) 0:tc=50;1:tc=-89;2:tc=18;3:tc=75;4:tc=-75;5:tc=-18;6:tc=89;default:tc=-50; endcase
            3'd6: case (i) 0:tc=36;1:tc=-83;2:tc=83;3:tc=-36;4:tc=-36;5:tc=83;6:tc=-83;default:tc=36; endcase
            default: case (i) 0:tc=18;1:tc=-50;2:tc=75;3:tc=-89;4:tc=89;5:tc=-75;6:tc=50;default:tc=-18; endcase
        endcase
    endfunction

    function automatic logic signed [15:0] rounded_clip(
        input logic signed [31:0] value, input integer shift
    );
        logic signed [31:0] shifted;
        begin
            shifted = (value + (32'sd1 <<< (shift - 1))) >>> shift;
            if (shifted > 32767) rounded_clip = 16'sd32767;
            else if (shifted < -32768) rounded_clip = -16'sd32768;
            else rounded_clip = shifted[15:0];
        end
    endfunction

    assign s_ready = state == LOAD;

    always_comb begin
        engine_sum = '0;
        for (k = 0; k < 8; k = k + 1) begin
            if (state == PASS1) begin
                engine_sample[k] = !INVERSE
                    ? input_memory[{pass1_row, k[2:0]}]
                    : input_memory[{k[2:0], pass1_output}];
                engine_coefficient[k] = !INVERSE
                    ? tc(pass1_output, k[2:0])
                    : tc(k[2:0], pass1_row);
            end else begin
                engine_sample[k] = !INVERSE
                    ? intermediate[{k[2:0], pass2_x}]
                    : intermediate[{pass2_y, k[2:0]}];
                engine_coefficient[k] = !INVERSE
                    ? tc(pass2_y, k[2:0])
                    : tc(k[2:0], pass2_x);
            end
            engine_sum = engine_sum + engine_sample[k] * engine_coefficient[k];
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= LOAD;
            load_address <= '0;
            pass1_row <= '0;
            pass1_output <= '0;
            pass2_x <= '0;
            pass2_y <= '0;
            m_valid <= 1'b0;
            m_data <= '0;
            m_x <= '0;
            m_y <= '0;
            m_block_last <= 1'b0;
        end else begin
            case (state)
                LOAD: begin
                    m_valid <= 1'b0;
                    if (s_valid) begin
                        input_memory[load_address] <= s_data;
                        if (load_address == 63) begin
                            load_address <= '0;
                            pass1_row <= '0;
                            pass1_output <= '0;
                            state <= PASS1;
                        end else load_address <= load_address + 1'b1;
                    end
                end
                PASS1: begin
                    intermediate[{pass1_row, pass1_output}] <= rounded_clip(
                        engine_sum, INVERSE ? 7 : 2);
                    if (pass1_output == 7) begin
                        pass1_output <= '0;
                        if (pass1_row == 7) begin
                            pass1_row <= '0;
                            pass2_x <= '0;
                            pass2_y <= '0;
                            m_valid <= 1'b0;
                            state <= PASS2;
                        end else pass1_row <= pass1_row + 1'b1;
                    end else pass1_output <= pass1_output + 1'b1;
                end
                PASS2: begin
                    if (!m_valid || m_ready) begin
                        if (m_valid && m_block_last) begin
                            m_valid <= 1'b0;
                            m_block_last <= 1'b0;
                            state <= LOAD;
                        end else begin
                            m_valid <= 1'b1;
                            m_data <= rounded_clip(engine_sum, INVERSE ? 12 : 9);
                            m_x <= pass2_x;
                            m_y <= pass2_y;
                            m_block_last <= (pass2_x == 7) && (pass2_y == 7);
                            if (pass2_x == 7) begin
                                pass2_x <= '0;
                                if (pass2_y != 7) pass2_y <= pass2_y + 1'b1;
                            end else pass2_x <= pass2_x + 1'b1;
                        end
                    end
                end
                default: state <= LOAD;
            endcase
        end
    end
endmodule
