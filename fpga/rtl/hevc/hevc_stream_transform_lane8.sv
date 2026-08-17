module hevc_stream_transform_lane8 #(
    parameter bit EXTERNAL_DATAPATH = 1'b0
) (
    input  logic                clk,
    input  logic                rst_n,
    input  logic                command_valid,
    output logic                command_ready,
    input  logic                command_inverse,
    input  logic                s_valid,
    output logic                s_ready,
    input  logic signed [15:0]  s_data,
    output logic                m_valid,
    input  logic                m_ready,
    output logic signed [15:0]  m_data,
    output logic [2:0]          m_x,
    output logic [2:0]          m_y,
    output logic                m_block_last,
    output logic                done,
    output logic                busy,
    output logic signed [127:0] mac_samples,
    output logic signed [63:0]  mac_coefficients,
    output logic                mac_enable,
    input  logic signed [191:0] mac_products,
    output logic                external_input_read_enable,
    output logic [2:0]          external_input_read_address,
    output logic [7:0]          external_input_write_enable,
    output logic [23:0]         external_input_write_address,
    output logic signed [127:0] external_input_write_data,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic signed [127:0] external_input_read_data,
    output logic                external_intermediate_read_enable,
    output logic [2:0]          external_intermediate_read_address,
    output logic [7:0]          external_intermediate_write_enable,
    output logic [23:0]         external_intermediate_write_address,
    output logic signed [127:0] external_intermediate_write_data,
    input  logic signed [127:0] external_intermediate_read_data,
    output logic                external_coefficient_read_enable,
    output logic [5:0]          external_coefficient_read_address,
    input  logic signed [63:0]  external_coefficient_read_data
    /* verilator lint_on UNUSEDSIGNAL */
);
    typedef enum logic [1:0] {IDLE, LOAD, PASS2} state_t;
    state_t state;
    logic inverse, load_complete;
    logic [2:0] load_x, load_y, pass1_x, pass1_y;
    logic [3:0] completed_units;
    logic pass1_issue_done, pass1_read_valid;
    logic [2:0] pass1_read_x, pass1_read_y;
    logic [2:0] pass2_x, pass2_y;
    logic pass2_issue_done, pass2_read_valid;
    logic [2:0] pass2_read_x, pass2_read_y;
    logic input_read_enable, intermediate_read_enable;
    logic [2:0] input_read_address, intermediate_read_address;
    logic input_write_enable [0:7];
    logic [2:0] input_write_address [0:7];
    logic signed [15:0] input_read_data [0:7];
    logic intermediate_write_enable [0:7];
    logic [2:0] intermediate_write_address [0:7];
    logic signed [15:0] intermediate_write_data [0:7];
    logic signed [15:0] intermediate_read_data [0:7];
    logic signed [15:0] pass1_value, pass2_value;
    logic signed [31:0] sum_level1 [0:3];
    logic signed [31:0] sum_level2 [0:1];
    logic signed [31:0] engine_sum;
    logic product_valid;
    logic [2:0] product_x, product_y;
    logic signed [31:0] pass1_sum_register;
    logic signed [31:0] pass2_sum_register;
    logic pass1_result_valid;
    logic [2:0] pass1_result_x, pass1_result_y;
    logic pass2_result_valid;
    logic [2:0] pass2_result_x, pass2_result_y;
    integer engine_lane;
    integer control_lane;

    wire command_fire = command_valid && command_ready;
    wire input_fire = s_valid && s_ready;
    wire output_fire = m_valid && m_ready;
    wire stream_unit_available = {1'b0, inverse ? pass1_x : pass1_y}
        < completed_units;
    wire pass1_issue = (state == LOAD) && !pass1_issue_done &&
        stream_unit_available;
    wire output_stage_ready = !m_valid || m_ready;
    wire pass2_result_ready = !pass2_result_valid || output_stage_ready;
    wire product_stage_ready = !product_valid ||
        ((state == LOAD) ? 1'b1 : pass2_result_ready);
    wire pass2_read_ready = !pass2_read_valid || product_stage_ready;
    wire pass2_issue = (state == PASS2) && !pass2_issue_done &&
        pass2_read_ready;
    wire product_input_valid = (state == LOAD) ? pass1_read_valid :
        ((state == PASS2) && pass2_read_valid);
    wire product_capture = product_stage_ready && product_input_valid;

    wire [2:0] coefficient_issue_index = input_read_enable ?
        (inverse ? pass1_y : pass1_x) :
        (inverse ? pass2_x : pass2_y);
    wire [5:0] coefficient_issue_address =
        {2'b10, inverse, coefficient_issue_index};
    function automatic logic signed [7:0] tc(
        input logic [2:0] row, input logic [2:0] column);
        logic signed [63:0] values;
        begin
            case (row)
                0: values = 64'h4040404040404040;
                1: values = 64'h594b3212eeceb5a7;
                2: values = 64'h5324dcadaddc2453;
                3: values = 64'h4beea7ce325912b5;
                4: values = 64'h40c0c04040c0c040;
                5: values = 64'h32a7124bb5ee59ce;
                6: values = 64'h24ad53dcdc53ad24;
                default: values = 64'h12ce4ba759b532ee;
            endcase
            tc = values[63 - (column * 8) -: 8];
        end
    endfunction

    function automatic logic signed [15:0] rounded(
        input logic signed [31:0] value, input logic [4:0] shift,
        input logic clip);
        logic signed [31:0] shifted;
        begin
            shifted = (value + (32'sd1 <<< (shift - 1'b1))) >>> shift;
            if (clip && shifted > 32767)
                rounded = 16'sd32767;
            else if (clip && shifted < -32768)
                rounded = -16'sd32768;
            else
                rounded = shifted[15:0];
        end
    endfunction

    genvar sum_lane;
    generate
        for (sum_lane = 0; sum_lane < 4; sum_lane = sum_lane + 1) begin : sum1
            assign sum_level1[sum_lane] =
                {{8{mac_products[(2*sum_lane)*24+23]}},
                    mac_products[(2*sum_lane)*24 +: 24]} +
                {{8{mac_products[(2*sum_lane+1)*24+23]}},
                    mac_products[(2*sum_lane+1)*24 +: 24]};
        end
        for (sum_lane = 0; sum_lane < 2; sum_lane = sum_lane + 1) begin : sum2
            assign sum_level2[sum_lane] =
                sum_level1[2*sum_lane] + sum_level1[2*sum_lane+1];
        end
    endgenerate
    assign engine_sum = sum_level2[0] + sum_level2[1];

    assign command_ready = state == IDLE;
    assign s_ready = (state == LOAD) && !load_complete;
    assign busy = state != IDLE;
    assign input_read_enable = pass1_issue;
    assign input_read_address = inverse ? pass1_x : pass1_y;
    assign intermediate_read_enable = pass2_issue;
    assign intermediate_read_address = inverse ? pass2_y : pass2_x;
    assign external_input_read_enable = input_read_enable;
    assign external_input_read_address = input_read_address;
    assign external_intermediate_read_enable = intermediate_read_enable;
    assign external_intermediate_read_address = intermediate_read_address;
    assign mac_enable = product_capture;

    assign external_coefficient_read_enable =
        input_read_enable || intermediate_read_enable;
    assign external_coefficient_read_address = coefficient_issue_address;

    always_comb begin
        for (engine_lane = 0; engine_lane < 8;
                engine_lane = engine_lane + 1) begin
            mac_samples[engine_lane * 16 +: 16] = (state == LOAD)
                ? input_read_data[engine_lane] :
                  intermediate_read_data[engine_lane];
            if (EXTERNAL_DATAPATH) begin
                mac_coefficients[engine_lane * 8 +: 8] =
                    external_coefficient_read_data[engine_lane * 8 +: 8];
            end else if (!inverse) begin
                mac_coefficients[engine_lane * 8 +: 8] = tc(
                    state == LOAD ? pass1_read_x : pass2_read_y,
                    engine_lane[2:0]);
            end else begin
                mac_coefficients[engine_lane * 8 +: 8] = tc(
                    engine_lane[2:0],
                    state == LOAD ? pass1_read_y : pass2_read_x);
            end
        end
        pass1_value = rounded(pass1_sum_register, inverse ? 5'd7 : 5'd2, inverse);
        pass2_value = rounded(pass2_sum_register,
            inverse ? 5'd12 : 5'd9, inverse);
    end

    always_comb begin
        for (control_lane = 0; control_lane < 8;
                control_lane = control_lane + 1) begin
            input_write_enable[control_lane] = 1'b0;
            input_write_address[control_lane] = '0;
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
        if (pass1_result_valid) begin
            if (!inverse) begin
                intermediate_write_enable[pass1_result_y] = 1'b1;
                intermediate_write_address[pass1_result_y] = pass1_result_x;
            end else begin
                intermediate_write_enable[pass1_result_x] = 1'b1;
                intermediate_write_address[pass1_result_x] = pass1_result_y;
            end
        end
        for (control_lane = 0; control_lane < 8;
                control_lane = control_lane + 1) begin
            external_input_write_enable[control_lane] =
                input_write_enable[control_lane];
            external_input_write_address[control_lane * 3 +: 3] =
                input_write_address[control_lane];
            external_input_write_data[control_lane * 16 +: 16] = s_data;
            external_intermediate_write_enable[control_lane] =
                intermediate_write_enable[control_lane];
            external_intermediate_write_address[control_lane * 3 +: 3] =
                intermediate_write_address[control_lane];
            external_intermediate_write_data[control_lane * 16 +: 16] =
                intermediate_write_data[control_lane];
        end
    end

    genvar bank;
    generate
        for (bank = 0; bank < 8; bank = bank + 1) begin : banks
            if (!EXTERNAL_DATAPATH) begin : internal
            hevc_transform_bank16 input_bank (
                .clk, .write_enable(input_write_enable[bank]),
                .write_address({1'b0, input_write_address[bank]}),
                .write_data(s_data), .read_enable(input_read_enable),
                .read_address({1'b0, input_read_address}),
                .read_data(input_read_data[bank]));
            hevc_transform_bank16 intermediate_bank (
                .clk, .write_enable(intermediate_write_enable[bank]),
                .write_address({1'b0, intermediate_write_address[bank]}),
                .write_data(intermediate_write_data[bank]),
                .read_enable(intermediate_read_enable),
                .read_address({1'b0, intermediate_read_address}),
                .read_data(intermediate_read_data[bank]));
            end else begin : external
                always_comb begin
                    input_read_data[bank] =
                        external_input_read_data[bank * 16 +: 16];
                    intermediate_read_data[bank] =
                        external_intermediate_read_data[bank * 16 +: 16];
                end
            end
        end
    endgenerate

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            inverse <= 1'b0;
            load_complete <= 1'b0;
            load_x <= '0; load_y <= '0; completed_units <= '0;
            pass1_x <= '0; pass1_y <= '0; pass1_issue_done <= 1'b0;
            pass1_read_valid <= 1'b0; pass1_read_x <= '0; pass1_read_y <= '0;
            product_valid <= 1'b0; product_x <= '0; product_y <= '0;
            pass1_sum_register <= '0; pass1_result_valid <= 1'b0;
            pass1_result_x <= '0; pass1_result_y <= '0;
            pass2_sum_register <= '0; pass2_result_valid <= 1'b0;
            pass2_result_x <= '0; pass2_result_y <= '0;
            pass2_x <= '0; pass2_y <= '0; pass2_issue_done <= 1'b0;
            pass2_read_valid <= 1'b0; pass2_read_x <= '0; pass2_read_y <= '0;
            m_valid <= 1'b0; m_data <= '0; m_x <= '0; m_y <= '0;
            m_block_last <= 1'b0; done <= 1'b0;
        end else begin
            done <= 1'b0;
            pass1_result_valid <= (state == LOAD) && product_valid;
            if ((state == LOAD) && product_valid) begin
                pass1_sum_register <= engine_sum;
                pass1_result_x <= product_x;
                pass1_result_y <= product_y;
            end
            if (product_stage_ready) begin
                product_valid <= product_input_valid;
                if (product_input_valid) begin
                    product_x <= (state == LOAD) ? pass1_read_x : pass2_read_x;
                    product_y <= (state == LOAD) ? pass1_read_y : pass2_read_y;
                end
            end
            case (state)
                IDLE: begin
                    m_valid <= 1'b0;
                    if (command_fire) begin
                        inverse <= command_inverse;
                        load_complete <= 1'b0;
                        load_x <= '0; load_y <= '0; completed_units <= '0;
                        pass1_x <= '0; pass1_y <= '0;
                        pass1_issue_done <= 1'b0; pass1_read_valid <= 1'b0;
                        pass1_result_valid <= 1'b0;
                        product_valid <= 1'b0;
                        state <= LOAD;
                    end
                end
                LOAD: begin
                    pass1_read_valid <= pass1_issue;
                    if (pass1_issue) begin
                        pass1_read_x <= pass1_x;
                        pass1_read_y <= pass1_y;
                        if (inverse) begin
                            if (pass1_y == 7) begin
                                pass1_y <= '0;
                                if (pass1_x == 7) pass1_issue_done <= 1'b1;
                                else pass1_x <= pass1_x + 1'b1;
                            end else pass1_y <= pass1_y + 1'b1;
                        end else begin
                            if (pass1_x == 7) begin
                                pass1_x <= '0;
                                if (pass1_y == 7) pass1_issue_done <= 1'b1;
                                else pass1_y <= pass1_y + 1'b1;
                            end else pass1_x <= pass1_x + 1'b1;
                        end
                    end
                    if (input_fire) begin
                        if (inverse) begin
                            if (load_y == 7) begin
                                load_y <= '0;
                                completed_units <= completed_units + 1'b1;
                                if (load_x == 7) load_complete <= 1'b1;
                                else load_x <= load_x + 1'b1;
                            end else load_y <= load_y + 1'b1;
                        end else begin
                            if (load_x == 7) begin
                                load_x <= '0;
                                completed_units <= completed_units + 1'b1;
                                if (load_y == 7) load_complete <= 1'b1;
                                else load_y <= load_y + 1'b1;
                            end else load_x <= load_x + 1'b1;
                        end
                    end
                    if (pass1_result_valid && pass1_result_x == 7 &&
                            pass1_result_y == 7) begin
                        pass1_read_valid <= 1'b0;
                        pass1_result_valid <= 1'b0;
                        pass2_x <= '0; pass2_y <= '0;
                        pass2_issue_done <= 1'b0; pass2_read_valid <= 1'b0;
                        pass2_result_valid <= 1'b0;
                        product_valid <= 1'b0;
                        state <= PASS2;
                    end
                end
                PASS2: begin
                    if (output_stage_ready) begin
                        m_valid <= pass2_result_valid;
                        if (pass2_result_valid) begin
                            m_data <= pass2_value;
                            m_x <= pass2_result_x;
                            m_y <= pass2_result_y;
                            m_block_last <= pass2_result_x == 7 &&
                                pass2_result_y == 7;
                        end
                    end
                    if (pass2_result_ready) begin
                        pass2_result_valid <= product_valid;
                        if (product_valid) begin
                            pass2_sum_register <= engine_sum;
                            pass2_result_x <= product_x;
                            pass2_result_y <= product_y;
                        end
                    end
                    if (pass2_read_ready) begin
                        pass2_read_valid <= pass2_issue;
                        if (pass2_issue) begin
                            pass2_read_x <= pass2_x;
                            pass2_read_y <= pass2_y;
                            if (pass2_x == 7) begin
                                pass2_x <= '0;
                                if (pass2_y == 7) pass2_issue_done <= 1'b1;
                                else pass2_y <= pass2_y + 1'b1;
                            end else pass2_x <= pass2_x + 1'b1;
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
