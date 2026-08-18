module custom_coefficient_scanner8 (
    input  logic                 clk,
    input  logic                 rst_n,

    input  logic                 start_valid,
    output logic                 start_ready,
    input  logic                 table_id,
    input  logic [5:0]           base_count,

    input  logic                 s_valid,
    output logic                 s_ready,
    input  logic signed [11:0]   s_coefficient,

    output logic                 m_valid,
    input  logic                 m_ready,
    output logic [1:0]           m_op_type,
    output logic                 m_layer,
    output logic                 m_mandatory,
    output logic [5:0]           m_reserve_release,
    output logic                 m_table_class,
    output logic                 m_table_id,
    output logic [7:0]           m_symbol,
    output logic [10:0]          m_amplitude,
    output logic [3:0]           m_amplitude_length,
    output logic                 m_raw_value,
    output logic [1:0]           m_raw_length,
    output logic                 m_eob_required,
    output logic                 m_last,

    output logic                 done,
    output logic                 busy,
    output logic                 coefficient_saturated,
    output logic                 input_error
);

    localparam logic [1:0] OP_RAW = 2'd0;
    localparam logic [1:0] OP_VLC = 2'd1;
    localparam logic [1:0] OP_SEGMENT_END = 2'd2;

    typedef enum logic [3:0] {
        IDLE,
        LOAD,
        EMIT_DC,
        EMIT_PREFIX,
        READ_COEFFICIENT,
        CAPTURE_COEFFICIENT,
        EMIT_ZRL,
        EMIT_AC,
        EMIT_SEGMENT_END
    } state_t;

    state_t state;
    logic active_table_id;
    logic [5:0] active_base_count;
    logic [5:0] load_index;

    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    logic signed [11:0] coefficient_memory [0:63];
    logic coefficient_read_enable;
    logic [5:0] coefficient_read_address;
    logic signed [11:0] coefficient_read_data;

    logic base_has_nonzero, enhancement_has_nonzero;
    logic [5:0] base_last_nonzero, enhancement_last_nonzero;
    logic signed [11:0] dc_coefficient;

    logic active_layer;
    logic segment_has_nonzero;
    logic [5:0] segment_start, segment_end, segment_last_nonzero;
    logic [5:0] scan_index;
    logic [5:0] zero_run;
    logic [1:0] zrl_remaining;
    logic [3:0] ac_run;
    logic signed [11:0] current_coefficient;
    logic output_fire;
    logic [3:0] current_category;
    logic [5:0] load_zigzag_index;

    function automatic logic [5:0] zigzag_address(input logic [5:0] index);
        case (index)
            0: zigzag_address = 0;   1: zigzag_address = 1;
            2: zigzag_address = 8;   3: zigzag_address = 16;
            4: zigzag_address = 9;   5: zigzag_address = 2;
            6: zigzag_address = 3;   7: zigzag_address = 10;
            8: zigzag_address = 17;  9: zigzag_address = 24;
            10: zigzag_address = 32; 11: zigzag_address = 25;
            12: zigzag_address = 18; 13: zigzag_address = 11;
            14: zigzag_address = 4;  15: zigzag_address = 5;
            16: zigzag_address = 12; 17: zigzag_address = 19;
            18: zigzag_address = 26; 19: zigzag_address = 33;
            20: zigzag_address = 40; 21: zigzag_address = 48;
            22: zigzag_address = 41; 23: zigzag_address = 34;
            24: zigzag_address = 27; 25: zigzag_address = 20;
            26: zigzag_address = 13; 27: zigzag_address = 6;
            28: zigzag_address = 7;  29: zigzag_address = 14;
            30: zigzag_address = 21; 31: zigzag_address = 28;
            32: zigzag_address = 35; 33: zigzag_address = 42;
            34: zigzag_address = 49; 35: zigzag_address = 56;
            36: zigzag_address = 57; 37: zigzag_address = 50;
            38: zigzag_address = 43; 39: zigzag_address = 36;
            40: zigzag_address = 29; 41: zigzag_address = 22;
            42: zigzag_address = 15; 43: zigzag_address = 23;
            44: zigzag_address = 30; 45: zigzag_address = 37;
            46: zigzag_address = 44; 47: zigzag_address = 51;
            48: zigzag_address = 58; 49: zigzag_address = 59;
            50: zigzag_address = 52; 51: zigzag_address = 45;
            52: zigzag_address = 38; 53: zigzag_address = 31;
            54: zigzag_address = 39; 55: zigzag_address = 46;
            56: zigzag_address = 53; 57: zigzag_address = 60;
            58: zigzag_address = 61; 59: zigzag_address = 54;
            60: zigzag_address = 47; 61: zigzag_address = 55;
            62: zigzag_address = 62; default: zigzag_address = 63;
        endcase
    endfunction

    function automatic logic [5:0] inverse_zigzag_index(input logic [5:0] address);
        case (address)
            0: inverse_zigzag_index = 0;   1: inverse_zigzag_index = 1;
            2: inverse_zigzag_index = 5;   3: inverse_zigzag_index = 6;
            4: inverse_zigzag_index = 14;  5: inverse_zigzag_index = 15;
            6: inverse_zigzag_index = 27;  7: inverse_zigzag_index = 28;
            8: inverse_zigzag_index = 2;   9: inverse_zigzag_index = 4;
            10: inverse_zigzag_index = 7;  11: inverse_zigzag_index = 13;
            12: inverse_zigzag_index = 16; 13: inverse_zigzag_index = 26;
            14: inverse_zigzag_index = 29; 15: inverse_zigzag_index = 42;
            16: inverse_zigzag_index = 3;  17: inverse_zigzag_index = 8;
            18: inverse_zigzag_index = 12; 19: inverse_zigzag_index = 17;
            20: inverse_zigzag_index = 25; 21: inverse_zigzag_index = 30;
            22: inverse_zigzag_index = 41; 23: inverse_zigzag_index = 43;
            24: inverse_zigzag_index = 9;  25: inverse_zigzag_index = 11;
            26: inverse_zigzag_index = 18; 27: inverse_zigzag_index = 24;
            28: inverse_zigzag_index = 31; 29: inverse_zigzag_index = 40;
            30: inverse_zigzag_index = 44; 31: inverse_zigzag_index = 53;
            32: inverse_zigzag_index = 10; 33: inverse_zigzag_index = 19;
            34: inverse_zigzag_index = 23; 35: inverse_zigzag_index = 32;
            36: inverse_zigzag_index = 39; 37: inverse_zigzag_index = 45;
            38: inverse_zigzag_index = 52; 39: inverse_zigzag_index = 54;
            40: inverse_zigzag_index = 20; 41: inverse_zigzag_index = 22;
            42: inverse_zigzag_index = 33; 43: inverse_zigzag_index = 38;
            44: inverse_zigzag_index = 46; 45: inverse_zigzag_index = 51;
            46: inverse_zigzag_index = 55; 47: inverse_zigzag_index = 60;
            48: inverse_zigzag_index = 21; 49: inverse_zigzag_index = 34;
            50: inverse_zigzag_index = 37; 51: inverse_zigzag_index = 47;
            52: inverse_zigzag_index = 50; 53: inverse_zigzag_index = 56;
            54: inverse_zigzag_index = 59; 55: inverse_zigzag_index = 61;
            56: inverse_zigzag_index = 35; 57: inverse_zigzag_index = 36;
            58: inverse_zigzag_index = 48; 59: inverse_zigzag_index = 49;
            60: inverse_zigzag_index = 57; 61: inverse_zigzag_index = 58;
            62: inverse_zigzag_index = 62; default: inverse_zigzag_index = 63;
        endcase
    endfunction

    function automatic logic [3:0] magnitude_category(
        input logic signed [11:0] value
    );
        logic [11:0] magnitude;
        begin
            magnitude = value < 0 ? -value : value;
            if (magnitude[11]) magnitude_category = 12;
            else if (magnitude[10]) magnitude_category = 11;
            else if (magnitude[9]) magnitude_category = 10;
            else if (magnitude[8]) magnitude_category = 9;
            else if (magnitude[7]) magnitude_category = 8;
            else if (magnitude[6]) magnitude_category = 7;
            else if (magnitude[5]) magnitude_category = 6;
            else if (magnitude[4]) magnitude_category = 5;
            else if (magnitude[3]) magnitude_category = 4;
            else if (magnitude[2]) magnitude_category = 3;
            else if (magnitude[1]) magnitude_category = 2;
            else if (magnitude[0]) magnitude_category = 1;
            else magnitude_category = 0;
        end
    endfunction

    function automatic logic [10:0] jpeg_amplitude(
        input logic signed [11:0] value,
        input logic [3:0] category
    );
        logic signed [12:0] converted;
        begin
            if (category == 0)
                converted = 0;
            else if (value < 0)
                converted = ((13'sd1 <<< category) - 1) + value;
            else
                converted = {value[11], value};
            jpeg_amplitude = (converted[12:11] == 0)
                ? converted[10:0] : 11'h7ff;
        end
    endfunction

    always_ff @(posedge clk) begin
        if (s_valid && s_ready)
            coefficient_memory[load_index] <= s_coefficient;
        if (coefficient_read_enable)
            coefficient_read_data <= coefficient_memory[coefficient_read_address];
    end

    always_comb begin
        coefficient_read_enable = 1'b0;
        coefficient_read_address = 6'd0;
        if (state == READ_COEFFICIENT) begin
            coefficient_read_enable = 1'b1;
            coefficient_read_address = zigzag_address(scan_index);
        end
    end

    always_comb begin
        start_ready = state == IDLE;
        s_ready = state == LOAD;
        busy = state != IDLE;
        current_category = magnitude_category(current_coefficient);
        load_zigzag_index = inverse_zigzag_index(load_index);

        m_valid = 1'b0;
        m_op_type = OP_RAW;
        m_layer = active_layer;
        m_mandatory = 1'b0;
        m_reserve_release = 0;
        m_table_class = 1'b1;
        m_table_id = active_table_id;
        m_symbol = 0;
        m_amplitude = 0;
        m_amplitude_length = 0;
        m_raw_value = 1'b0;
        m_raw_length = 0;
        m_eob_required = 1'b0;
        m_last = 1'b0;

        case (state)
            EMIT_DC: begin
                m_valid = 1'b1;
                m_op_type = OP_VLC;
                m_layer = 1'b0;
                m_mandatory = 1'b1;
                m_reserve_release = active_table_id ? 22 : 20;
                m_table_class = 1'b0;
                m_symbol = {4'd0, magnitude_category(dc_coefficient)};
                m_amplitude_length = magnitude_category(dc_coefficient);
                m_amplitude = jpeg_amplitude(
                    dc_coefficient, magnitude_category(dc_coefficient)
                );
            end
            EMIT_PREFIX: begin
                m_valid = 1'b1;
                m_op_type = OP_RAW;
                m_mandatory = 1'b1;
                m_reserve_release = 1;
                m_raw_value = segment_has_nonzero;
                m_raw_length = 1;
            end
            EMIT_ZRL: begin
                m_valid = 1'b1;
                m_op_type = OP_VLC;
                m_symbol = 8'hf0;
            end
            EMIT_AC: begin
                m_valid = 1'b1;
                m_op_type = OP_VLC;
                m_symbol = {ac_run, current_category};
                m_amplitude_length = current_category;
                m_amplitude = jpeg_amplitude(current_coefficient, current_category);
            end
            EMIT_SEGMENT_END: begin
                m_valid = 1'b1;
                m_op_type = OP_SEGMENT_END;
                m_mandatory = 1'b1;
                m_reserve_release = active_table_id ? 2 : 4;
                m_eob_required = segment_has_nonzero
                    ? (segment_last_nonzero < segment_end)
                    : active_table_id;
                m_last = active_layer;
            end
            default: begin end
        endcase
    end

    assign output_fire = m_valid && m_ready;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            active_table_id <= 1'b0;
            active_base_count <= 0;
            load_index <= 0;
            base_has_nonzero <= 1'b0;
            enhancement_has_nonzero <= 1'b0;
            base_last_nonzero <= 0;
            enhancement_last_nonzero <= 0;
            dc_coefficient <= 0;
            active_layer <= 1'b0;
            segment_has_nonzero <= 1'b0;
            segment_start <= 0;
            segment_end <= 0;
            segment_last_nonzero <= 0;
            scan_index <= 0;
            zero_run <= 0;
            zrl_remaining <= 0;
            ac_run <= 0;
            current_coefficient <= 0;
            done <= 1'b0;
            coefficient_saturated <= 1'b0;
            input_error <= 1'b0;
        end else begin
            done <= 1'b0;

            case (state)
                IDLE: begin
                    if (start_valid && start_ready) begin
                        input_error <= 1'b0;
                        coefficient_saturated <= 1'b0;
                        if (base_count <= 1) begin
                            input_error <= 1'b1;
                        end else begin
                            active_table_id <= table_id;
                            active_base_count <= base_count;
                            load_index <= 0;
                            base_has_nonzero <= 1'b0;
                            enhancement_has_nonzero <= 1'b0;
                            base_last_nonzero <= 0;
                            enhancement_last_nonzero <= 0;
                            dc_coefficient <= 0;
                            state <= LOAD;
                        end
                    end
                end

                LOAD: begin
                    if (s_valid && s_ready) begin
                        if (load_zigzag_index == 0) begin
                            if (s_coefficient == -12'sd2048) begin
                                dc_coefficient <= -12'sd2047;
                                coefficient_saturated <= 1'b1;
                            end else begin
                                dc_coefficient <= s_coefficient;
                            end
                        end else begin
                            if ((s_coefficient > 12'sd1023)
                                    || (s_coefficient < -12'sd1023))
                                coefficient_saturated <= 1'b1;
                            if (s_coefficient != 0) begin
                                if (load_zigzag_index < active_base_count) begin
                                    base_has_nonzero <= 1'b1;
                                    if (!base_has_nonzero
                                            || (load_zigzag_index > base_last_nonzero))
                                        base_last_nonzero <= load_zigzag_index;
                                end else begin
                                    enhancement_has_nonzero <= 1'b1;
                                    if (!enhancement_has_nonzero
                                            || (load_zigzag_index
                                                > enhancement_last_nonzero))
                                        enhancement_last_nonzero <= load_zigzag_index;
                                end
                            end
                        end
                        if (load_index == 63) begin
                            state <= EMIT_DC;
                        end else begin
                            load_index <= load_index + 1'b1;
                        end
                    end
                end

                EMIT_DC: begin
                    if (output_fire) begin
                        active_layer <= 1'b0;
                        segment_start <= 1;
                        segment_end <= active_base_count - 1'b1;
                        segment_has_nonzero <= base_has_nonzero;
                        segment_last_nonzero <= base_last_nonzero;
                        scan_index <= 1;
                        zero_run <= 0;
                        if (active_table_id)
                            state <= base_has_nonzero
                                ? READ_COEFFICIENT : EMIT_SEGMENT_END;
                        else
                            state <= EMIT_PREFIX;
                    end
                end

                EMIT_PREFIX: begin
                    if (output_fire) begin
                        if (segment_has_nonzero) begin
                            scan_index <= segment_start;
                            zero_run <= 0;
                            state <= READ_COEFFICIENT;
                        end else begin
                            state <= EMIT_SEGMENT_END;
                        end
                    end
                end

                READ_COEFFICIENT: begin
                    state <= CAPTURE_COEFFICIENT;
                end

                CAPTURE_COEFFICIENT: begin
                    if (coefficient_read_data == 0) begin
                        zero_run <= zero_run + 1'b1;
                        scan_index <= scan_index + 1'b1;
                        state <= READ_COEFFICIENT;
                    end else begin
                        if (coefficient_read_data > 12'sd1023)
                            current_coefficient <= 12'sd1023;
                        else if (coefficient_read_data < -12'sd1023)
                            current_coefficient <= -12'sd1023;
                        else
                            current_coefficient <= coefficient_read_data;
                        zrl_remaining <= zero_run[5:4];
                        ac_run <= zero_run[3:0];
                        state <= (zero_run >= 16) ? EMIT_ZRL : EMIT_AC;
                    end
                end

                EMIT_ZRL: begin
                    if (output_fire) begin
                        if (zrl_remaining > 1)
                            zrl_remaining <= zrl_remaining - 1'b1;
                        else
                            state <= EMIT_AC;
                    end
                end

                EMIT_AC: begin
                    if (output_fire) begin
                        zero_run <= 0;
                        if (scan_index == segment_last_nonzero) begin
                            state <= EMIT_SEGMENT_END;
                        end else begin
                            scan_index <= scan_index + 1'b1;
                            state <= READ_COEFFICIENT;
                        end
                    end
                end

                EMIT_SEGMENT_END: begin
                    if (output_fire) begin
                        if (!active_layer) begin
                            active_layer <= 1'b1;
                            segment_start <= active_base_count;
                            segment_end <= 63;
                            segment_has_nonzero <= enhancement_has_nonzero;
                            segment_last_nonzero <= enhancement_last_nonzero;
                            scan_index <= active_base_count;
                            zero_run <= 0;
                            if (active_table_id)
                                state <= enhancement_has_nonzero
                                    ? READ_COEFFICIENT : EMIT_SEGMENT_END;
                            else
                                state <= EMIT_PREFIX;
                        end else begin
                            state <= IDLE;
                            done <= 1'b1;
                        end
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
