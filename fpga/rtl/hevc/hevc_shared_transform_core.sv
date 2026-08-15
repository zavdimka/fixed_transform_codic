module hevc_shared_transform_core #(
    parameter bit STREAM_FORWARD_PASS1 = 1'b0,
    parameter bit STREAM_INVERSE_PASS1 = 1'b0
) (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               command_valid,
    output logic               command_ready,
    input  logic               command_size8,
    input  logic               command_inverse,
    input  logic               s_valid,
    output logic               s_ready,
    input  logic signed [15:0] s_data,
    output logic               m_valid,
    input  logic               m_ready,
    output logic signed [15:0] m_data,
    output logic [3:0]         m_x,
    output logic [3:0]         m_y,
    output logic               m_block_last,
    output logic               done,
    output logic               protocol_error,
    output logic               busy
);
    typedef enum logic [1:0] {IDLE, LOAD, PASS1, PASS2} state_t;
    state_t state;

    logic size8, inverse;
    logic [3:0] load_x, load_y;
    logic load_complete;
    logic [4:0] completed_units;
    logic [3:0] pass1_x, pass1_y;
    logic pass1_issue_done, pass1_read_valid;
    logic [3:0] pass1_read_x, pass1_read_y;
    logic [3:0] pass2_x, pass2_y;
    logic pass2_issue_done, pass2_read_valid;
    logic [3:0] pass2_read_x, pass2_read_y;

    logic input_read_enable;
    logic [3:0] input_read_address;
    logic input_write_enable [0:15];
    logic [3:0] input_write_address [0:15];
    logic signed [15:0] input_write_data [0:15];
    logic signed [15:0] input_read_data [0:15];
    logic intermediate_read_enable;
    logic [3:0] intermediate_read_address;
    logic intermediate_write_enable [0:15];
    logic [3:0] intermediate_write_address [0:15];
    logic signed [15:0] intermediate_write_data [0:15];
    logic signed [15:0] intermediate_read_data [0:15];

    logic signed [31:0] engine_sum;
    logic signed [15:0] engine_sample [0:15];
    logic signed [7:0] engine_coefficient [0:15];
    logic signed [255:0] engine_samples_flat;
    logic signed [127:0] engine_coefficients_flat;
    logic signed [15:0] pass1_value;
    logic signed [15:0] pass2_value;
    integer engine_lane;
    integer control_lane;

    wire command_fire = command_valid && command_ready;
    wire input_fire = s_valid && s_ready;
    wire output_fire = m_valid && m_ready;
    wire [3:0] final_coordinate = size8 ? 4'd7 : 4'd15;
    wire output_stage_ready = !m_valid || m_ready;
    wire streaming_forward = STREAM_FORWARD_PASS1 && !inverse;
    wire streaming_inverse = STREAM_INVERSE_PASS1 && inverse;
    wire streaming_pass1 = streaming_forward || streaming_inverse;
    wire [3:0] stream_unit = streaming_inverse ? pass1_x : pass1_y;
    wire stream_unit_available = {1'b0, stream_unit} < completed_units;
    wire stream_pass1_issue = (state == LOAD) && streaming_pass1 &&
        !pass1_issue_done && stream_unit_available;
    wire pass1_compute = (state == PASS1) ||
        ((state == LOAD) && streaming_pass1);
    wire pass2_read_ready = !pass2_read_valid || output_stage_ready;
    wire pass2_issue = (state == PASS2) && !pass2_issue_done &&
        pass2_read_ready;

    function automatic logic signed [7:0] coefficient16(
        input logic [3:0] row,
        input logic [3:0] column
    );
        logic signed [127:0] values;
        begin
            case (row)
                0: values = 128'h40404040404040404040404040404040;
                1: values = 128'h5a575046392b1909f7e7d5c7bab0a9a6;
                2: values = 128'h594b3212eeceb5a7a7b5ceee12324b59;
                3: values = 128'h573909d5b0a6bae719465a502bf7c7a9;
                4: values = 128'h5324dcadaddc24535324dcadaddc2453;
                5: values = 128'h5009baa9e7395a2bd5a6c7195746f7b0;
                6: values = 128'h4beea7ce325912b5b5125932cea7ee4b;
                7: values = 128'h46d5a9095a19b0c73950e7a6f7572bba;
                8: values = 128'h40c0c04040c0c04040c0c04040c0c040;
                9: values = 128'h39b0e75af7a92b46bad55709a61950c7;
                10: values = 128'h32a7124bb5ee59cece59eeb54b12a732;
                11: values = 128'h2ba63919a94609b050f7ba57e7c75ad5;
                12: values = 128'h24ad53dcdc53ad2424ad53dcdc53ad24;
                13: values = 128'h19ba5ab02b09c757a939f7d550a646e7;
                14: values = 128'h12ce4ba759b532eeee32b559a74bce12;
                default: values = 128'h09e72bc746b057a65aa950ba39d519f7;
            endcase
            coefficient16 = values[127 - (column * 8) -: 8];
        end
    endfunction

    function automatic logic signed [15:0] rounded(
        input logic signed [31:0] value,
        input logic [4:0] shift,
        input logic clip
    );
        logic signed [31:0] shifted;
        begin
            shifted = (value + (32'sd1 <<< (shift - 1'b1))) >>> shift;
            if (clip && (shifted > 32767))
                rounded = 16'sd32767;
            else if (clip && (shifted < -32768))
                rounded = -16'sd32768;
            else
                rounded = shifted[15:0];
        end
    endfunction

    assign command_ready = state == IDLE;
    assign s_ready = (state == LOAD) && !load_complete;
    assign busy = state != IDLE;
    assign protocol_error = 1'b0;

    always_comb begin
        for (engine_lane = 0; engine_lane < 16; engine_lane = engine_lane + 1) begin
            engine_sample[engine_lane] = '0;
            engine_coefficient[engine_lane] = '0;
            if (engine_lane <= final_coordinate) begin
                engine_sample[engine_lane] = pass1_compute ?
                    input_read_data[engine_lane] :
                    intermediate_read_data[engine_lane];
                if (!inverse) begin
                    engine_coefficient[engine_lane] = coefficient16(
                        size8 ? {(pass1_compute ? pass1_read_x[2:0] :
                            pass2_read_y[2:0]), 1'b0} :
                            (pass1_compute ? pass1_read_x : pass2_read_y),
                        engine_lane[3:0]);
                end else begin
                    engine_coefficient[engine_lane] = coefficient16(
                        size8 ? {engine_lane[2:0], 1'b0} : engine_lane[3:0],
                        pass1_compute ? pass1_read_y : pass2_read_x);
                end
            end
            engine_samples_flat[engine_lane * 16 +: 16] =
                engine_sample[engine_lane];
            engine_coefficients_flat[engine_lane * 8 +: 8] =
                engine_coefficient[engine_lane];
        end
        pass1_value = rounded(engine_sum,
            inverse ? 5'd7 : (size8 ? 5'd2 : 5'd3), inverse);
        pass2_value = rounded(engine_sum,
            inverse ? 5'd12 : (size8 ? 5'd9 : 5'd10), inverse);
    end

    hevc_transform_mac16 mac (
        .samples(engine_samples_flat),
        .coefficients(engine_coefficients_flat),
        .sum(engine_sum)
    );

    always_comb begin
        input_read_enable = ((state == PASS1) && !pass1_issue_done) ||
            stream_pass1_issue;
        input_read_address = inverse ? pass1_x : pass1_y;
        intermediate_read_enable = pass2_issue;
        intermediate_read_address = inverse ? pass2_y : pass2_x;
        for (control_lane = 0; control_lane < 16; control_lane = control_lane + 1) begin
            input_write_enable[control_lane] = 1'b0;
            input_write_address[control_lane] = '0;
            input_write_data[control_lane] = s_data;
            intermediate_write_enable[control_lane] = 1'b0;
            intermediate_write_address[control_lane] = '0;
            intermediate_write_data[control_lane] = pass1_value;
        end
        if (input_fire) begin
            if (!inverse) begin
                input_write_enable[load_x] = 1'b1;
                input_write_address[load_x] = load_y;
            end else begin
                input_write_enable[load_y] = 1'b1;
                input_write_address[load_y] = load_x;
            end
        end
        if (pass1_compute && pass1_read_valid) begin
            if (!inverse) begin
                intermediate_write_enable[pass1_read_y] = 1'b1;
                intermediate_write_address[pass1_read_y] = pass1_read_x;
            end else begin
                intermediate_write_enable[pass1_read_x] = 1'b1;
                intermediate_write_address[pass1_read_x] = pass1_read_y;
            end
        end
    end

    genvar bank;
    generate
        for (bank = 0; bank < 16; bank = bank + 1) begin : banks
            hevc_transform_bank16 input_bank (
                .clk(clk), .write_enable(input_write_enable[bank]),
                .write_address(input_write_address[bank]),
                .write_data(input_write_data[bank]),
                .read_enable(input_read_enable),
                .read_address(input_read_address),
                .read_data(input_read_data[bank])
            );
            hevc_transform_bank16 intermediate_bank (
                .clk(clk), .write_enable(intermediate_write_enable[bank]),
                .write_address(intermediate_write_address[bank]),
                .write_data(intermediate_write_data[bank]),
                .read_enable(intermediate_read_enable),
                .read_address(intermediate_read_address),
                .read_data(intermediate_read_data[bank])
            );
        end
    endgenerate

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            size8 <= 1'b0;
            inverse <= 1'b0;
            load_x <= '0;
            load_y <= '0;
            load_complete <= 1'b0;
            completed_units <= '0;
            pass1_x <= '0;
            pass1_y <= '0;
            pass1_issue_done <= 1'b0;
            pass1_read_valid <= 1'b0;
            pass1_read_x <= '0;
            pass1_read_y <= '0;
            pass2_x <= '0;
            pass2_y <= '0;
            pass2_issue_done <= 1'b0;
            pass2_read_valid <= 1'b0;
            pass2_read_x <= '0;
            pass2_read_y <= '0;
            m_valid <= 1'b0;
            m_data <= '0;
            m_x <= '0;
            m_y <= '0;
            m_block_last <= 1'b0;
            done <= 1'b0;
        end else begin
            done <= 1'b0;
            case (state)
                IDLE: begin
                    m_valid <= 1'b0;
                    if (command_fire) begin
                        size8 <= command_size8;
                        inverse <= command_inverse;
                        load_x <= '0;
                        load_y <= '0;
                        load_complete <= 1'b0;
                        completed_units <= '0;
                        pass1_x <= '0;
                        pass1_y <= '0;
                        pass1_issue_done <= 1'b0;
                        pass1_read_valid <= 1'b0;
                        state <= LOAD;
                    end
                end
                LOAD: begin
                    if (streaming_pass1) begin
                        pass1_read_valid <= stream_pass1_issue;
                        if (stream_pass1_issue) begin
                            pass1_read_x <= pass1_x;
                            pass1_read_y <= pass1_y;
                            if (streaming_inverse) begin
                                if (pass1_y == final_coordinate) begin
                                    pass1_y <= '0;
                                    if (pass1_x == final_coordinate)
                                        pass1_issue_done <= 1'b1;
                                    else
                                        pass1_x <= pass1_x + 1'b1;
                                end else begin
                                    pass1_y <= pass1_y + 1'b1;
                                end
                            end else begin
                                if (pass1_x == final_coordinate) begin
                                    pass1_x <= '0;
                                    if (pass1_y == final_coordinate)
                                        pass1_issue_done <= 1'b1;
                                    else
                                        pass1_y <= pass1_y + 1'b1;
                                end else begin
                                    pass1_x <= pass1_x + 1'b1;
                                end
                            end
                        end
                    end
                    if (input_fire) begin
                        if (streaming_inverse) begin
                            if (load_y == final_coordinate) begin
                                load_y <= '0;
                                completed_units <= completed_units + 1'b1;
                                if (load_x == final_coordinate) begin
                                    load_x <= '0;
                                    load_complete <= 1'b1;
                                end else begin
                                    load_x <= load_x + 1'b1;
                                end
                            end else begin
                                load_y <= load_y + 1'b1;
                            end
                        end else begin
                            if (load_x == final_coordinate) begin
                                load_x <= '0;
                                completed_units <= completed_units + 1'b1;
                                if (load_y == final_coordinate) begin
                                    load_y <= '0;
                                    if (streaming_forward) begin
                                        load_complete <= 1'b1;
                                    end else begin
                                        pass1_x <= '0;
                                        pass1_y <= '0;
                                        pass1_issue_done <= 1'b0;
                                        pass1_read_valid <= 1'b0;
                                        state <= PASS1;
                                    end
                                end else begin
                                    load_y <= load_y + 1'b1;
                                end
                            end else begin
                                load_x <= load_x + 1'b1;
                            end
                        end
                    end
                    if (streaming_pass1 && pass1_read_valid &&
                            (pass1_read_x == final_coordinate) &&
                            (pass1_read_y == final_coordinate)) begin
                        pass1_read_valid <= 1'b0;
                        pass2_x <= '0;
                        pass2_y <= '0;
                        pass2_issue_done <= 1'b0;
                        pass2_read_valid <= 1'b0;
                        state <= PASS2;
                    end
                end
                PASS1: begin
                    pass1_read_valid <= !pass1_issue_done;
                    if (!pass1_issue_done) begin
                        pass1_read_x <= pass1_x;
                        pass1_read_y <= pass1_y;
                        if (pass1_x == final_coordinate) begin
                            pass1_x <= '0;
                            if (pass1_y == final_coordinate)
                                pass1_issue_done <= 1'b1;
                            else
                                pass1_y <= pass1_y + 1'b1;
                        end else begin
                            pass1_x <= pass1_x + 1'b1;
                        end
                    end
                    if (pass1_read_valid &&
                            (pass1_read_x == final_coordinate) &&
                            (pass1_read_y == final_coordinate)) begin
                        pass1_read_valid <= 1'b0;
                        pass2_x <= '0;
                        pass2_y <= '0;
                        pass2_issue_done <= 1'b0;
                        pass2_read_valid <= 1'b0;
                        state <= PASS2;
                    end
                end
                PASS2: begin
                    if (output_stage_ready) begin
                        m_valid <= pass2_read_valid;
                        if (pass2_read_valid) begin
                            m_data <= pass2_value;
                            m_x <= pass2_read_x;
                            m_y <= pass2_read_y;
                            m_block_last <=
                                (pass2_read_x == final_coordinate) &&
                                (pass2_read_y == final_coordinate);
                        end
                    end

                    if (pass2_read_ready) begin
                        pass2_read_valid <= pass2_issue;
                        if (pass2_issue) begin
                            pass2_read_x <= pass2_x;
                            pass2_read_y <= pass2_y;
                            if (pass2_x == final_coordinate) begin
                                pass2_x <= '0;
                                if (pass2_y == final_coordinate)
                                    pass2_issue_done <= 1'b1;
                                else
                                    pass2_y <= pass2_y + 1'b1;
                            end else begin
                                pass2_x <= pass2_x + 1'b1;
                            end
                        end
                    end

                    if (output_fire && m_block_last) begin
                        state <= IDLE;
                        done <= 1'b1;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
