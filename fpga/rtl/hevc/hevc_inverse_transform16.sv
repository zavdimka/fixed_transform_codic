module hevc_inverse_transform16 (
    input  logic               clk,
    input  logic               rst_n,

    input  logic               s_valid,
    output logic               s_ready,
    input  logic signed [15:0] s_coefficient,

    output logic               m_valid,
    input  logic               m_ready,
    output logic signed [15:0] m_residual,
    output logic [3:0]         m_x,
    output logic [3:0]         m_y,
    output logic               m_block_last
);
    typedef enum logic [1:0] {
        ROW_INPUT,
        DRAIN_ROW,
        COLUMN_PROCESS,
        DRAIN_OUTPUT
    } state_t;

    state_t state;
    logic signed [26:0] accumulator_a [0:15];
    logic signed [26:0] accumulator_b [0:15];
    logic buffer_write_enable;
    logic [7:0] buffer_write_address;
    logic signed [15:0] buffer_write_data;
    logic buffer_read_enable;
    logic [7:0] buffer_read_address;
    logic active_bank;

    logic [3:0] row_index;
    logic [3:0] pixel_x;
    logic [3:0] drain_index;

    logic [3:0] column_index;
    logic [4:0] column_issue_position;
    logic       column_read_valid;
    logic [3:0] column_read_position;
    logic signed [15:0] intermediate_read_data;
    logic column_advance;

    logic signed [15:0] engine_input;
    logic [3:0] engine_position;
    logic signed [23:0] products [0:15];
    integer product_index;
    integer accumulator_index;

    function automatic logic signed [7:0] inverse_transform_coefficient(
        input logic [3:0] output_index,
        input logic [3:0] input_index
    );
        case (output_index)
            4'd0: begin
                case (input_index)
                    4'd0: inverse_transform_coefficient = 8'sd64;
                    4'd1: inverse_transform_coefficient = 8'sd64;
                    4'd2: inverse_transform_coefficient = 8'sd64;
                    4'd3: inverse_transform_coefficient = 8'sd64;
                    4'd4: inverse_transform_coefficient = 8'sd64;
                    4'd5: inverse_transform_coefficient = 8'sd64;
                    4'd6: inverse_transform_coefficient = 8'sd64;
                    4'd7: inverse_transform_coefficient = 8'sd64;
                    4'd8: inverse_transform_coefficient = 8'sd64;
                    4'd9: inverse_transform_coefficient = 8'sd64;
                    4'd10: inverse_transform_coefficient = 8'sd64;
                    4'd11: inverse_transform_coefficient = 8'sd64;
                    4'd12: inverse_transform_coefficient = 8'sd64;
                    4'd13: inverse_transform_coefficient = 8'sd64;
                    4'd14: inverse_transform_coefficient = 8'sd64;
                    4'd15: inverse_transform_coefficient = 8'sd64;
                    default: inverse_transform_coefficient = '0;
                endcase
            end
            4'd1: begin
                case (input_index)
                    4'd0: inverse_transform_coefficient = 8'sd90;
                    4'd1: inverse_transform_coefficient = 8'sd87;
                    4'd2: inverse_transform_coefficient = 8'sd80;
                    4'd3: inverse_transform_coefficient = 8'sd70;
                    4'd4: inverse_transform_coefficient = 8'sd57;
                    4'd5: inverse_transform_coefficient = 8'sd43;
                    4'd6: inverse_transform_coefficient = 8'sd25;
                    4'd7: inverse_transform_coefficient = 8'sd9;
                    4'd8: inverse_transform_coefficient = -8'sd9;
                    4'd9: inverse_transform_coefficient = -8'sd25;
                    4'd10: inverse_transform_coefficient = -8'sd43;
                    4'd11: inverse_transform_coefficient = -8'sd57;
                    4'd12: inverse_transform_coefficient = -8'sd70;
                    4'd13: inverse_transform_coefficient = -8'sd80;
                    4'd14: inverse_transform_coefficient = -8'sd87;
                    4'd15: inverse_transform_coefficient = -8'sd90;
                    default: inverse_transform_coefficient = '0;
                endcase
            end
            4'd2: begin
                case (input_index)
                    4'd0: inverse_transform_coefficient = 8'sd89;
                    4'd1: inverse_transform_coefficient = 8'sd75;
                    4'd2: inverse_transform_coefficient = 8'sd50;
                    4'd3: inverse_transform_coefficient = 8'sd18;
                    4'd4: inverse_transform_coefficient = -8'sd18;
                    4'd5: inverse_transform_coefficient = -8'sd50;
                    4'd6: inverse_transform_coefficient = -8'sd75;
                    4'd7: inverse_transform_coefficient = -8'sd89;
                    4'd8: inverse_transform_coefficient = -8'sd89;
                    4'd9: inverse_transform_coefficient = -8'sd75;
                    4'd10: inverse_transform_coefficient = -8'sd50;
                    4'd11: inverse_transform_coefficient = -8'sd18;
                    4'd12: inverse_transform_coefficient = 8'sd18;
                    4'd13: inverse_transform_coefficient = 8'sd50;
                    4'd14: inverse_transform_coefficient = 8'sd75;
                    4'd15: inverse_transform_coefficient = 8'sd89;
                    default: inverse_transform_coefficient = '0;
                endcase
            end
            4'd3: begin
                case (input_index)
                    4'd0: inverse_transform_coefficient = 8'sd87;
                    4'd1: inverse_transform_coefficient = 8'sd57;
                    4'd2: inverse_transform_coefficient = 8'sd9;
                    4'd3: inverse_transform_coefficient = -8'sd43;
                    4'd4: inverse_transform_coefficient = -8'sd80;
                    4'd5: inverse_transform_coefficient = -8'sd90;
                    4'd6: inverse_transform_coefficient = -8'sd70;
                    4'd7: inverse_transform_coefficient = -8'sd25;
                    4'd8: inverse_transform_coefficient = 8'sd25;
                    4'd9: inverse_transform_coefficient = 8'sd70;
                    4'd10: inverse_transform_coefficient = 8'sd90;
                    4'd11: inverse_transform_coefficient = 8'sd80;
                    4'd12: inverse_transform_coefficient = 8'sd43;
                    4'd13: inverse_transform_coefficient = -8'sd9;
                    4'd14: inverse_transform_coefficient = -8'sd57;
                    4'd15: inverse_transform_coefficient = -8'sd87;
                    default: inverse_transform_coefficient = '0;
                endcase
            end
            4'd4: begin
                case (input_index)
                    4'd0: inverse_transform_coefficient = 8'sd83;
                    4'd1: inverse_transform_coefficient = 8'sd36;
                    4'd2: inverse_transform_coefficient = -8'sd36;
                    4'd3: inverse_transform_coefficient = -8'sd83;
                    4'd4: inverse_transform_coefficient = -8'sd83;
                    4'd5: inverse_transform_coefficient = -8'sd36;
                    4'd6: inverse_transform_coefficient = 8'sd36;
                    4'd7: inverse_transform_coefficient = 8'sd83;
                    4'd8: inverse_transform_coefficient = 8'sd83;
                    4'd9: inverse_transform_coefficient = 8'sd36;
                    4'd10: inverse_transform_coefficient = -8'sd36;
                    4'd11: inverse_transform_coefficient = -8'sd83;
                    4'd12: inverse_transform_coefficient = -8'sd83;
                    4'd13: inverse_transform_coefficient = -8'sd36;
                    4'd14: inverse_transform_coefficient = 8'sd36;
                    4'd15: inverse_transform_coefficient = 8'sd83;
                    default: inverse_transform_coefficient = '0;
                endcase
            end
            4'd5: begin
                case (input_index)
                    4'd0: inverse_transform_coefficient = 8'sd80;
                    4'd1: inverse_transform_coefficient = 8'sd9;
                    4'd2: inverse_transform_coefficient = -8'sd70;
                    4'd3: inverse_transform_coefficient = -8'sd87;
                    4'd4: inverse_transform_coefficient = -8'sd25;
                    4'd5: inverse_transform_coefficient = 8'sd57;
                    4'd6: inverse_transform_coefficient = 8'sd90;
                    4'd7: inverse_transform_coefficient = 8'sd43;
                    4'd8: inverse_transform_coefficient = -8'sd43;
                    4'd9: inverse_transform_coefficient = -8'sd90;
                    4'd10: inverse_transform_coefficient = -8'sd57;
                    4'd11: inverse_transform_coefficient = 8'sd25;
                    4'd12: inverse_transform_coefficient = 8'sd87;
                    4'd13: inverse_transform_coefficient = 8'sd70;
                    4'd14: inverse_transform_coefficient = -8'sd9;
                    4'd15: inverse_transform_coefficient = -8'sd80;
                    default: inverse_transform_coefficient = '0;
                endcase
            end
            4'd6: begin
                case (input_index)
                    4'd0: inverse_transform_coefficient = 8'sd75;
                    4'd1: inverse_transform_coefficient = -8'sd18;
                    4'd2: inverse_transform_coefficient = -8'sd89;
                    4'd3: inverse_transform_coefficient = -8'sd50;
                    4'd4: inverse_transform_coefficient = 8'sd50;
                    4'd5: inverse_transform_coefficient = 8'sd89;
                    4'd6: inverse_transform_coefficient = 8'sd18;
                    4'd7: inverse_transform_coefficient = -8'sd75;
                    4'd8: inverse_transform_coefficient = -8'sd75;
                    4'd9: inverse_transform_coefficient = 8'sd18;
                    4'd10: inverse_transform_coefficient = 8'sd89;
                    4'd11: inverse_transform_coefficient = 8'sd50;
                    4'd12: inverse_transform_coefficient = -8'sd50;
                    4'd13: inverse_transform_coefficient = -8'sd89;
                    4'd14: inverse_transform_coefficient = -8'sd18;
                    4'd15: inverse_transform_coefficient = 8'sd75;
                    default: inverse_transform_coefficient = '0;
                endcase
            end
            4'd7: begin
                case (input_index)
                    4'd0: inverse_transform_coefficient = 8'sd70;
                    4'd1: inverse_transform_coefficient = -8'sd43;
                    4'd2: inverse_transform_coefficient = -8'sd87;
                    4'd3: inverse_transform_coefficient = 8'sd9;
                    4'd4: inverse_transform_coefficient = 8'sd90;
                    4'd5: inverse_transform_coefficient = 8'sd25;
                    4'd6: inverse_transform_coefficient = -8'sd80;
                    4'd7: inverse_transform_coefficient = -8'sd57;
                    4'd8: inverse_transform_coefficient = 8'sd57;
                    4'd9: inverse_transform_coefficient = 8'sd80;
                    4'd10: inverse_transform_coefficient = -8'sd25;
                    4'd11: inverse_transform_coefficient = -8'sd90;
                    4'd12: inverse_transform_coefficient = -8'sd9;
                    4'd13: inverse_transform_coefficient = 8'sd87;
                    4'd14: inverse_transform_coefficient = 8'sd43;
                    4'd15: inverse_transform_coefficient = -8'sd70;
                    default: inverse_transform_coefficient = '0;
                endcase
            end
            4'd8: begin
                case (input_index)
                    4'd0: inverse_transform_coefficient = 8'sd64;
                    4'd1: inverse_transform_coefficient = -8'sd64;
                    4'd2: inverse_transform_coefficient = -8'sd64;
                    4'd3: inverse_transform_coefficient = 8'sd64;
                    4'd4: inverse_transform_coefficient = 8'sd64;
                    4'd5: inverse_transform_coefficient = -8'sd64;
                    4'd6: inverse_transform_coefficient = -8'sd64;
                    4'd7: inverse_transform_coefficient = 8'sd64;
                    4'd8: inverse_transform_coefficient = 8'sd64;
                    4'd9: inverse_transform_coefficient = -8'sd64;
                    4'd10: inverse_transform_coefficient = -8'sd64;
                    4'd11: inverse_transform_coefficient = 8'sd64;
                    4'd12: inverse_transform_coefficient = 8'sd64;
                    4'd13: inverse_transform_coefficient = -8'sd64;
                    4'd14: inverse_transform_coefficient = -8'sd64;
                    4'd15: inverse_transform_coefficient = 8'sd64;
                    default: inverse_transform_coefficient = '0;
                endcase
            end
            4'd9: begin
                case (input_index)
                    4'd0: inverse_transform_coefficient = 8'sd57;
                    4'd1: inverse_transform_coefficient = -8'sd80;
                    4'd2: inverse_transform_coefficient = -8'sd25;
                    4'd3: inverse_transform_coefficient = 8'sd90;
                    4'd4: inverse_transform_coefficient = -8'sd9;
                    4'd5: inverse_transform_coefficient = -8'sd87;
                    4'd6: inverse_transform_coefficient = 8'sd43;
                    4'd7: inverse_transform_coefficient = 8'sd70;
                    4'd8: inverse_transform_coefficient = -8'sd70;
                    4'd9: inverse_transform_coefficient = -8'sd43;
                    4'd10: inverse_transform_coefficient = 8'sd87;
                    4'd11: inverse_transform_coefficient = 8'sd9;
                    4'd12: inverse_transform_coefficient = -8'sd90;
                    4'd13: inverse_transform_coefficient = 8'sd25;
                    4'd14: inverse_transform_coefficient = 8'sd80;
                    4'd15: inverse_transform_coefficient = -8'sd57;
                    default: inverse_transform_coefficient = '0;
                endcase
            end
            4'd10: begin
                case (input_index)
                    4'd0: inverse_transform_coefficient = 8'sd50;
                    4'd1: inverse_transform_coefficient = -8'sd89;
                    4'd2: inverse_transform_coefficient = 8'sd18;
                    4'd3: inverse_transform_coefficient = 8'sd75;
                    4'd4: inverse_transform_coefficient = -8'sd75;
                    4'd5: inverse_transform_coefficient = -8'sd18;
                    4'd6: inverse_transform_coefficient = 8'sd89;
                    4'd7: inverse_transform_coefficient = -8'sd50;
                    4'd8: inverse_transform_coefficient = -8'sd50;
                    4'd9: inverse_transform_coefficient = 8'sd89;
                    4'd10: inverse_transform_coefficient = -8'sd18;
                    4'd11: inverse_transform_coefficient = -8'sd75;
                    4'd12: inverse_transform_coefficient = 8'sd75;
                    4'd13: inverse_transform_coefficient = 8'sd18;
                    4'd14: inverse_transform_coefficient = -8'sd89;
                    4'd15: inverse_transform_coefficient = 8'sd50;
                    default: inverse_transform_coefficient = '0;
                endcase
            end
            4'd11: begin
                case (input_index)
                    4'd0: inverse_transform_coefficient = 8'sd43;
                    4'd1: inverse_transform_coefficient = -8'sd90;
                    4'd2: inverse_transform_coefficient = 8'sd57;
                    4'd3: inverse_transform_coefficient = 8'sd25;
                    4'd4: inverse_transform_coefficient = -8'sd87;
                    4'd5: inverse_transform_coefficient = 8'sd70;
                    4'd6: inverse_transform_coefficient = 8'sd9;
                    4'd7: inverse_transform_coefficient = -8'sd80;
                    4'd8: inverse_transform_coefficient = 8'sd80;
                    4'd9: inverse_transform_coefficient = -8'sd9;
                    4'd10: inverse_transform_coefficient = -8'sd70;
                    4'd11: inverse_transform_coefficient = 8'sd87;
                    4'd12: inverse_transform_coefficient = -8'sd25;
                    4'd13: inverse_transform_coefficient = -8'sd57;
                    4'd14: inverse_transform_coefficient = 8'sd90;
                    4'd15: inverse_transform_coefficient = -8'sd43;
                    default: inverse_transform_coefficient = '0;
                endcase
            end
            4'd12: begin
                case (input_index)
                    4'd0: inverse_transform_coefficient = 8'sd36;
                    4'd1: inverse_transform_coefficient = -8'sd83;
                    4'd2: inverse_transform_coefficient = 8'sd83;
                    4'd3: inverse_transform_coefficient = -8'sd36;
                    4'd4: inverse_transform_coefficient = -8'sd36;
                    4'd5: inverse_transform_coefficient = 8'sd83;
                    4'd6: inverse_transform_coefficient = -8'sd83;
                    4'd7: inverse_transform_coefficient = 8'sd36;
                    4'd8: inverse_transform_coefficient = 8'sd36;
                    4'd9: inverse_transform_coefficient = -8'sd83;
                    4'd10: inverse_transform_coefficient = 8'sd83;
                    4'd11: inverse_transform_coefficient = -8'sd36;
                    4'd12: inverse_transform_coefficient = -8'sd36;
                    4'd13: inverse_transform_coefficient = 8'sd83;
                    4'd14: inverse_transform_coefficient = -8'sd83;
                    4'd15: inverse_transform_coefficient = 8'sd36;
                    default: inverse_transform_coefficient = '0;
                endcase
            end
            4'd13: begin
                case (input_index)
                    4'd0: inverse_transform_coefficient = 8'sd25;
                    4'd1: inverse_transform_coefficient = -8'sd70;
                    4'd2: inverse_transform_coefficient = 8'sd90;
                    4'd3: inverse_transform_coefficient = -8'sd80;
                    4'd4: inverse_transform_coefficient = 8'sd43;
                    4'd5: inverse_transform_coefficient = 8'sd9;
                    4'd6: inverse_transform_coefficient = -8'sd57;
                    4'd7: inverse_transform_coefficient = 8'sd87;
                    4'd8: inverse_transform_coefficient = -8'sd87;
                    4'd9: inverse_transform_coefficient = 8'sd57;
                    4'd10: inverse_transform_coefficient = -8'sd9;
                    4'd11: inverse_transform_coefficient = -8'sd43;
                    4'd12: inverse_transform_coefficient = 8'sd80;
                    4'd13: inverse_transform_coefficient = -8'sd90;
                    4'd14: inverse_transform_coefficient = 8'sd70;
                    4'd15: inverse_transform_coefficient = -8'sd25;
                    default: inverse_transform_coefficient = '0;
                endcase
            end
            4'd14: begin
                case (input_index)
                    4'd0: inverse_transform_coefficient = 8'sd18;
                    4'd1: inverse_transform_coefficient = -8'sd50;
                    4'd2: inverse_transform_coefficient = 8'sd75;
                    4'd3: inverse_transform_coefficient = -8'sd89;
                    4'd4: inverse_transform_coefficient = 8'sd89;
                    4'd5: inverse_transform_coefficient = -8'sd75;
                    4'd6: inverse_transform_coefficient = 8'sd50;
                    4'd7: inverse_transform_coefficient = -8'sd18;
                    4'd8: inverse_transform_coefficient = -8'sd18;
                    4'd9: inverse_transform_coefficient = 8'sd50;
                    4'd10: inverse_transform_coefficient = -8'sd75;
                    4'd11: inverse_transform_coefficient = 8'sd89;
                    4'd12: inverse_transform_coefficient = -8'sd89;
                    4'd13: inverse_transform_coefficient = 8'sd75;
                    4'd14: inverse_transform_coefficient = -8'sd50;
                    4'd15: inverse_transform_coefficient = 8'sd18;
                    default: inverse_transform_coefficient = '0;
                endcase
            end
            4'd15: begin
                case (input_index)
                    4'd0: inverse_transform_coefficient = 8'sd9;
                    4'd1: inverse_transform_coefficient = -8'sd25;
                    4'd2: inverse_transform_coefficient = 8'sd43;
                    4'd3: inverse_transform_coefficient = -8'sd57;
                    4'd4: inverse_transform_coefficient = 8'sd70;
                    4'd5: inverse_transform_coefficient = -8'sd80;
                    4'd6: inverse_transform_coefficient = 8'sd87;
                    4'd7: inverse_transform_coefficient = -8'sd90;
                    4'd8: inverse_transform_coefficient = 8'sd90;
                    4'd9: inverse_transform_coefficient = -8'sd87;
                    4'd10: inverse_transform_coefficient = 8'sd80;
                    4'd11: inverse_transform_coefficient = -8'sd70;
                    4'd12: inverse_transform_coefficient = 8'sd57;
                    4'd13: inverse_transform_coefficient = -8'sd43;
                    4'd14: inverse_transform_coefficient = 8'sd25;
                    4'd15: inverse_transform_coefficient = -8'sd9;
                    default: inverse_transform_coefficient = '0;
                endcase
            end
            default: inverse_transform_coefficient = '0;
        endcase
    endfunction

    function automatic logic signed [15:0] clip_round_shift_7(
        input logic signed [26:0] value
    );
        logic signed [26:0] shifted;
        begin
            shifted = (value + 27'sd64) >>> 7;
            if (shifted > 32767) begin
                clip_round_shift_7 = 16'sd32767;
            end else if (shifted < -32768) begin
                clip_round_shift_7 = -16'sd32768;
            end else begin
                clip_round_shift_7 = shifted[15:0];
            end
        end
    endfunction

    function automatic logic signed [15:0] clip_round_shift_12(
        input logic signed [26:0] value
    );
        logic signed [26:0] shifted;
        begin
            shifted = (value + 27'sd2048) >>> 12;
            if (shifted > 32767) begin
                clip_round_shift_12 = 16'sd32767;
            end else if (shifted < -32768) begin
                clip_round_shift_12 = -16'sd32768;
            end else begin
                clip_round_shift_12 = shifted[15:0];
            end
        end
    endfunction

    assign s_ready = state == ROW_INPUT;
    assign column_advance = !m_valid || m_ready;

    always_comb begin
        if (state == ROW_INPUT) begin
            engine_input = s_coefficient;
            engine_position = pixel_x;
        end else begin
            engine_input = intermediate_read_data;
            engine_position = column_read_position;
        end

        for (product_index = 0; product_index < 16;
             product_index = product_index + 1) begin
            products[product_index] = engine_input
                * inverse_transform_coefficient(engine_position, product_index[3:0]);
        end
    end

    always_comb begin
        buffer_write_enable = 1'b0;
        buffer_write_address = '0;
        buffer_write_data = '0;
        buffer_read_enable = 1'b0;
        buffer_read_address = '0;

        if ((state == ROW_INPUT) && s_valid && s_ready &&
            (row_index != 0)) begin
            buffer_write_enable = 1'b1;
            buffer_write_address = {pixel_x, row_index - 1'b1};
            buffer_write_data = clip_round_shift_7(active_bank
                ? accumulator_a[pixel_x] : accumulator_b[pixel_x]);
        end else if (state == DRAIN_ROW) begin
            buffer_write_enable = 1'b1;
            buffer_write_address = {drain_index, 4'd15};
            buffer_write_data = clip_round_shift_7(active_bank
                ? accumulator_b[drain_index] : accumulator_a[drain_index]);
        end

        if ((state == COLUMN_PROCESS) && column_advance &&
            (column_issue_position < 16)) begin
            buffer_read_enable = 1'b1;
            buffer_read_address = {column_index,
                                   column_issue_position[3:0]};
        end
    end

    hevc_transform_buffer16 intermediate_buffer (
        .clk(clk),
        .write_enable(buffer_write_enable),
        .write_address(buffer_write_address),
        .write_data(buffer_write_data),
        .read_enable(buffer_read_enable),
        .read_address(buffer_read_address),
        .read_data(intermediate_read_data)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state                   <= ROW_INPUT;
            active_bank             <= 1'b0;
            row_index               <= '0;
            pixel_x                 <= '0;
            drain_index             <= '0;
            column_index            <= '0;
            column_issue_position   <= '0;
            column_read_valid       <= 1'b0;
            column_read_position    <= '0;
            m_valid                 <= 1'b0;
            m_residual           <= '0;
            m_x                     <= '0;
            m_y                     <= '0;
            m_block_last            <= 1'b0;
        end else begin
            if (m_valid && m_ready) begin
                m_valid <= 1'b0;
            end

            case (state)
                ROW_INPUT: begin
                    if (s_valid && s_ready) begin
                        for (accumulator_index = 0; accumulator_index < 16;
                             accumulator_index = accumulator_index + 1) begin
                            if (!active_bank) begin
                                if (pixel_x == 0) begin
                                    accumulator_a[accumulator_index]
                                        <= {{3{products[accumulator_index][23]}},
                                             products[accumulator_index]};
                                end else begin
                                    accumulator_a[accumulator_index]
                                        <= accumulator_a[accumulator_index]
                                         + {{3{products[accumulator_index][23]}},
                                              products[accumulator_index]};
                                end
                            end else begin
                                if (pixel_x == 0) begin
                                    accumulator_b[accumulator_index]
                                        <= {{3{products[accumulator_index][23]}},
                                             products[accumulator_index]};
                                end else begin
                                    accumulator_b[accumulator_index]
                                        <= accumulator_b[accumulator_index]
                                         + {{3{products[accumulator_index][23]}},
                                              products[accumulator_index]};
                                end
                            end
                        end

                        if (pixel_x == 15) begin
                            pixel_x <= '0;
                            if (row_index == 15) begin
                                drain_index <= '0;
                                state <= DRAIN_ROW;
                            end else begin
                                row_index <= row_index + 1'b1;
                                active_bank <= ~active_bank;
                            end
                        end else begin
                            pixel_x <= pixel_x + 1'b1;
                        end
                    end
                end

                DRAIN_ROW: begin
                    if (drain_index == 15) begin
                        active_bank <= 1'b0;
                        column_index <= '0;
                        column_issue_position <= '0;
                        column_read_valid <= 1'b0;
                        state <= COLUMN_PROCESS;
                    end else begin
                        drain_index <= drain_index + 1'b1;
                    end
                end

                COLUMN_PROCESS: begin
                    if (column_advance) begin
                        if (column_read_valid) begin
                            for (accumulator_index = 0;
                                 accumulator_index < 16;
                                 accumulator_index = accumulator_index + 1) begin
                                if (!active_bank) begin
                                    if (column_read_position == 0) begin
                                        accumulator_a[accumulator_index]
                                            <= {{3{products[accumulator_index][23]}},
                                                 products[accumulator_index]};
                                    end else begin
                                        accumulator_a[accumulator_index]
                                            <= accumulator_a[accumulator_index]
                                             + {{3{products[accumulator_index][23]}},
                                                  products[accumulator_index]};
                                    end
                                end else begin
                                    if (column_read_position == 0) begin
                                        accumulator_b[accumulator_index]
                                            <= {{3{products[accumulator_index][23]}},
                                                 products[accumulator_index]};
                                    end else begin
                                        accumulator_b[accumulator_index]
                                            <= accumulator_b[accumulator_index]
                                             + {{3{products[accumulator_index][23]}},
                                                  products[accumulator_index]};
                                    end
                                end
                            end

                            if (column_index != 0) begin
                                m_valid <= 1'b1;
                                m_residual <= clip_round_shift_12(active_bank
                                    ? accumulator_a[column_read_position]
                                    : accumulator_b[column_read_position]);
                                m_x <= column_read_position;
                                m_y <= column_index - 1'b1;
                                m_block_last <= 1'b0;
                            end
                        end

                        if (column_issue_position < 16) begin
                            column_read_position
                                <= column_issue_position[3:0];
                            column_issue_position
                                <= column_issue_position + 1'b1;
                            column_read_valid <= 1'b1;
                        end else begin
                            column_read_valid <= 1'b0;
                        end

                        if (column_read_valid &&
                            (column_read_position == 15)) begin
                            column_read_valid <= 1'b0;
                            column_issue_position <= '0;
                            if (column_index == 15) begin
                                drain_index <= '0;
                                state <= DRAIN_OUTPUT;
                            end else begin
                                column_index <= column_index + 1'b1;
                                active_bank <= ~active_bank;
                            end
                        end
                    end
                end

                DRAIN_OUTPUT: begin
                    if (!m_valid || m_ready) begin
                        m_valid <= 1'b1;
                        m_residual <= clip_round_shift_12(active_bank
                            ? accumulator_b[drain_index]
                            : accumulator_a[drain_index]);
                        m_x <= drain_index;
                        m_y <= 4'd15;
                        m_block_last <= drain_index == 15;
                        if (drain_index == 15) begin
                            active_bank <= 1'b0;
                            row_index <= '0;
                            pixel_x <= '0;
                            state <= ROW_INPUT;
                        end else begin
                            drain_index <= drain_index + 1'b1;
                        end
                    end
                end

                default: state <= ROW_INPUT;
            endcase
        end
    end
endmodule

