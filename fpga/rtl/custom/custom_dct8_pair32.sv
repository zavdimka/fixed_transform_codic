module custom_dct8_pair32 (
    input  logic                       clk,
    input  logic                       rst_n,

    input  logic                       command_valid,
    output logic                       command_ready,

    input  logic                       s_valid,
    output logic                       s_ready,
    input  logic signed [127:0]        s_row_a,
    input  logic signed [127:0]        s_row_b,

    output logic                       m_valid,
    input  logic                       m_ready,
    output logic [5:0]                 m_index,
    output logic signed [15:0]         m_a0,
    output logic signed [15:0]         m_a1,
    output logic signed [15:0]         m_b0,
    output logic signed [15:0]         m_b1,
    output logic                       m_last,

    output logic                       done,
    output logic                       busy,
    output logic                       saturated
);
    typedef enum logic [2:0] {
        IDLE, LOAD, PASS1_COLUMN, PASS1, PASS1_DRAIN, PASS2, PASS2_DRAIN
    } state_t;
    state_t state;

    logic [2:0] load_row;
    logic [4:0] issue_count;
    logic product_valid;
    logic [2:0] product_major;
    logic [2:0] product_minor0;
    logic result_valid;
    logic [2:0] result_major;
    logic [2:0] result_minor0;
    logic result_pass1;
    logic rounded_valid;
    logic [2:0] rounded_major;
    logic [2:0] rounded_minor0;
    logic rounded_pass1;

    logic signed [15:0] work_a [0:63];
    logic signed [15:0] work_b [0:63];
    logic signed [127:0] column_a, column_b;

    logic signed [127:0] mac_samples_a, mac_samples_b;
    logic signed [111:0] mac_coefficients_0, mac_coefficients_1;
    logic signed [239:0] products_a0, products_a1;
    logic signed [239:0] products_b0, products_b1;
    logic mac_enable;
    logic signed [31:0] sum_a0, sum_a1, sum_b0, sum_b1;
    logic signed [31:0] registered_sum_a0, registered_sum_a1;
    logic signed [31:0] registered_sum_b0, registered_sum_b1;
    logic signed [31:0] product_a0 [0:7];
    logic signed [31:0] product_a1 [0:7];
    logic signed [31:0] product_b0 [0:7];
    logic signed [31:0] product_b1 [0:7];
    logic signed [31:0] sum1_a0 [0:3];
    logic signed [31:0] sum1_a1 [0:3];
    logic signed [31:0] sum1_b0 [0:3];
    logic signed [31:0] sum1_b1 [0:3];
    logic signed [31:0] sum2_a0 [0:1];
    logic signed [31:0] sum2_a1 [0:1];
    logic signed [31:0] sum2_b0 [0:1];
    logic signed [31:0] sum2_b1 [0:1];
    logic signed [31:0] rounded_a0, rounded_a1, rounded_b0, rounded_b1;
    logic signed [31:0] registered_rounded_a0, registered_rounded_a1;
    logic signed [31:0] registered_rounded_b0, registered_rounded_b1;
    logic signed [15:0] clipped_a0, clipped_a1, clipped_b0, clipped_b1;
    logic result_saturated;
    integer read_lane;
    integer load_lane;

    wire command_fire = command_valid && command_ready;
    wire input_fire = s_valid && s_ready;
    wire output_fire = m_valid && m_ready;
    wire pass1_phase = (state == PASS1) || (state == PASS1_DRAIN);
    wire output_stage_ready = !m_valid || m_ready;
    wire rounded_stage_ready = !rounded_valid || rounded_pass1
                             || output_stage_ready;
    wire result_stage_ready = !result_valid || rounded_stage_ready;
    wire product_stage_ready = !product_valid || pass1_phase
                             || result_stage_ready;
    wire mac_issue = ((state == PASS1) || (state == PASS2))
                   && ((state == PASS1) || product_stage_ready);

    function automatic logic signed [111:0] coefficient_vector(
        input logic [2:0] index
    );
        begin
            case (index)
                3'd0: coefficient_vector = {
                    14'sd5793, 14'sd5793, 14'sd5793, 14'sd5793,
                    14'sd5793, 14'sd5793, 14'sd5793, 14'sd5793};
                3'd1: coefficient_vector = {
                    -14'sd8035, -14'sd6811, -14'sd4551, -14'sd1598,
                    14'sd1598, 14'sd4551, 14'sd6811, 14'sd8035};
                3'd2: coefficient_vector = {
                    14'sd7568, 14'sd3135, -14'sd3135, -14'sd7568,
                    -14'sd7568, -14'sd3135, 14'sd3135, 14'sd7568};
                3'd3: coefficient_vector = {
                    -14'sd6811, 14'sd1598, 14'sd8035, 14'sd4551,
                    -14'sd4551, -14'sd8035, -14'sd1598, 14'sd6811};
                3'd4: coefficient_vector = {
                    14'sd5793, -14'sd5793, -14'sd5793, 14'sd5793,
                    14'sd5793, -14'sd5793, -14'sd5793, 14'sd5793};
                3'd5: coefficient_vector = {
                    -14'sd4551, 14'sd8035, -14'sd1598, -14'sd6811,
                    14'sd6811, 14'sd1598, -14'sd8035, 14'sd4551};
                3'd6: coefficient_vector = {
                    14'sd3135, -14'sd7568, 14'sd7568, -14'sd3135,
                    -14'sd3135, 14'sd7568, -14'sd7568, 14'sd3135};
                default: coefficient_vector = {
                    -14'sd1598, 14'sd4551, -14'sd6811, 14'sd8035,
                    -14'sd8035, 14'sd6811, -14'sd4551, 14'sd1598};
            endcase
        end
    endfunction

    function automatic logic signed [31:0] round_q14(
        input logic signed [31:0] value
    );
        logic signed [31:0] magnitude;
        begin
            magnitude = value < 0 ? -value : value;
            magnitude = (magnitude + 32'sd8192) >>> 14;
            round_q14 = value < 0 ? -magnitude : magnitude;
        end
    endfunction

    function automatic logic signed [15:0] clip13(
        input logic signed [31:0] value
    );
        begin
            if (value > 32'sd4095)
                clip13 = 16'sd4095;
            else if (value < -32'sd4096)
                clip13 = -16'sd4096;
            else
                clip13 = value[15:0];
        end
    endfunction

    function automatic logic signed [15:0] clip16(
        input logic signed [31:0] value
    );
        begin
            if (value > 32'sd32767)
                clip16 = 16'sd32767;
            else if (value < -32'sd32768)
                clip16 = -16'sd32768;
            else
                clip16 = value[15:0];
        end
    endfunction

    assign command_ready = state == IDLE;
    assign s_ready = state == LOAD;
    assign busy = state != IDLE;
    assign mac_enable = mac_issue;

    /* verilator lint_off WIDTHEXPAND */
    always_comb begin
        mac_samples_a = '0;
        mac_samples_b = '0;
        read_lane = 0;
        if (state == PASS1) begin
            for (read_lane = 0; read_lane < 8; read_lane = read_lane + 1) begin
                mac_samples_a[read_lane * 16 +: 16] =
                    column_a[read_lane * 16 +: 16];
                mac_samples_b[read_lane * 16 +: 16] =
                    column_b[read_lane * 16 +: 16];
            end
        end else if (state == PASS2) begin
            for (read_lane = 0; read_lane < 8; read_lane = read_lane + 1) begin
                mac_samples_a[read_lane * 16 +: 16] =
                    work_a[issue_count[4:2] * 8 + read_lane];
                mac_samples_b[read_lane * 16 +: 16] =
                    work_b[issue_count[4:2] * 8 + read_lane];
            end
        end
        mac_coefficients_0 = coefficient_vector({issue_count[1:0], 1'b0});
        mac_coefficients_1 = coefficient_vector({issue_count[1:0], 1'b1});
    end
    /* verilator lint_on WIDTHEXPAND */

    genvar sum_lane;
    generate
        for (sum_lane = 0; sum_lane < 8; sum_lane = sum_lane + 1) begin : extend
            assign product_a0[sum_lane] =
                {{2{products_a0[sum_lane * 30 + 29]}},
                 products_a0[sum_lane * 30 +: 30]};
            assign product_a1[sum_lane] =
                {{2{products_a1[sum_lane * 30 + 29]}},
                 products_a1[sum_lane * 30 +: 30]};
            assign product_b0[sum_lane] =
                {{2{products_b0[sum_lane * 30 + 29]}},
                 products_b0[sum_lane * 30 +: 30]};
            assign product_b1[sum_lane] =
                {{2{products_b1[sum_lane * 30 + 29]}},
                 products_b1[sum_lane * 30 +: 30]};
        end
        for (sum_lane = 0; sum_lane < 4; sum_lane = sum_lane + 1) begin : add1
            assign sum1_a0[sum_lane] = product_a0[2 * sum_lane]
                + product_a0[2 * sum_lane + 1];
            assign sum1_a1[sum_lane] = product_a1[2 * sum_lane]
                + product_a1[2 * sum_lane + 1];
            assign sum1_b0[sum_lane] = product_b0[2 * sum_lane]
                + product_b0[2 * sum_lane + 1];
            assign sum1_b1[sum_lane] = product_b1[2 * sum_lane]
                + product_b1[2 * sum_lane + 1];
        end
        for (sum_lane = 0; sum_lane < 2; sum_lane = sum_lane + 1) begin : add2
            assign sum2_a0[sum_lane] = sum1_a0[2 * sum_lane]
                + sum1_a0[2 * sum_lane + 1];
            assign sum2_a1[sum_lane] = sum1_a1[2 * sum_lane]
                + sum1_a1[2 * sum_lane + 1];
            assign sum2_b0[sum_lane] = sum1_b0[2 * sum_lane]
                + sum1_b0[2 * sum_lane + 1];
            assign sum2_b1[sum_lane] = sum1_b1[2 * sum_lane]
                + sum1_b1[2 * sum_lane + 1];
        end
    endgenerate

    always_comb begin
        sum_a0 = sum2_a0[0] + sum2_a0[1];
        sum_a1 = sum2_a1[0] + sum2_a1[1];
        sum_b0 = sum2_b0[0] + sum2_b0[1];
        sum_b1 = sum2_b1[0] + sum2_b1[1];
        rounded_a0 = round_q14(registered_sum_a0);
        rounded_a1 = round_q14(registered_sum_a1);
        rounded_b0 = round_q14(registered_sum_b0);
        rounded_b1 = round_q14(registered_sum_b1);
        if (rounded_pass1) begin
            clipped_a0 = clip13(registered_rounded_a0);
            clipped_a1 = clip13(registered_rounded_a1);
            clipped_b0 = clip13(registered_rounded_b0);
            clipped_b1 = clip13(registered_rounded_b1);
            result_saturated = (registered_rounded_a0 > 32'sd4095)
                || (registered_rounded_a0 < -32'sd4096)
                || (registered_rounded_a1 > 32'sd4095)
                || (registered_rounded_a1 < -32'sd4096)
                || (registered_rounded_b0 > 32'sd4095)
                || (registered_rounded_b0 < -32'sd4096)
                || (registered_rounded_b1 > 32'sd4095)
                || (registered_rounded_b1 < -32'sd4096);
        end else begin
            clipped_a0 = clip16(registered_rounded_a0);
            clipped_a1 = clip16(registered_rounded_a1);
            clipped_b0 = clip16(registered_rounded_b0);
            clipped_b1 = clip16(registered_rounded_b1);
            result_saturated = (registered_rounded_a0 > 32'sd32767)
                || (registered_rounded_a0 < -32'sd32768)
                || (registered_rounded_a1 > 32'sd32767)
                || (registered_rounded_a1 < -32'sd32768)
                || (registered_rounded_b0 > 32'sd32767)
                || (registered_rounded_b0 < -32'sd32768)
                || (registered_rounded_b1 > 32'sd32767)
                || (registered_rounded_b1 < -32'sd32768);
        end
    end

    custom_dct8_mac32 mac (
        .clk(clk), .enable(mac_enable),
        .samples_a(mac_samples_a),
        .coefficients_0(mac_coefficients_0),
        .coefficients_1(mac_coefficients_1),
        .products_a0(products_a0), .products_a1(products_a1),
        .samples_b(mac_samples_b),
        .products_b0(products_b0), .products_b1(products_b1)
    );

    /* verilator lint_off WIDTHEXPAND */
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            load_row <= '0;
            issue_count <= '0;
            product_valid <= 1'b0;
            result_valid <= 1'b0;
            rounded_valid <= 1'b0;
            done <= 1'b0;
            saturated <= 1'b0;
            m_valid <= 1'b0;
        end else begin
            done <= 1'b0;
            if (command_fire) begin
                state <= LOAD;
                load_row <= '0;
                issue_count <= '0;
                product_valid <= 1'b0;
                result_valid <= 1'b0;
                rounded_valid <= 1'b0;
                saturated <= 1'b0;
            end

            if (input_fire) begin
                for (load_lane = 0; load_lane < 8; load_lane = load_lane + 1) begin
                    work_a[load_row * 8 + load_lane] <=
                        s_row_a[load_lane * 16 +: 16];
                    work_b[load_row * 8 + load_lane] <=
                        s_row_b[load_lane * 16 +: 16];
                end
                if (load_row == 3'd7) begin
                    state <= PASS1_COLUMN;
                    issue_count <= '0;
                    result_valid <= 1'b0;
                end else begin
                    load_row <= load_row + 1'b1;
                end
            end

            if (state == PASS1_COLUMN) begin
                for (load_lane = 0; load_lane < 8; load_lane = load_lane + 1) begin
                    column_a[load_lane * 16 +: 16] <=
                        work_a[load_lane * 8 + issue_count[4:2]];
                    column_b[load_lane * 16 +: 16] <=
                        work_b[load_lane * 8 + issue_count[4:2]];
                end
                state <= PASS1;
            end

            if (mac_issue) begin
                product_valid <= 1'b1;
                product_major <= issue_count[4:2];
                product_minor0 <= {issue_count[1:0], 1'b0};
                if ((state == PASS1) && (issue_count[1:0] == 2'd3)) begin
                    state <= PASS1_DRAIN;
                    issue_count <= issue_count + 1'b1;
                end else if ((state == PASS2) && (issue_count == 5'd31)) begin
                    state <= PASS2_DRAIN;
                    issue_count <= '0;
                end else begin
                    issue_count <= issue_count + 1'b1;
                end
            end else if (product_stage_ready) begin
                product_valid <= 1'b0;
            end

            if (result_stage_ready) begin
                result_valid <= product_valid;
                if (product_valid) begin
                    registered_sum_a0 <= sum_a0;
                    registered_sum_a1 <= sum_a1;
                    registered_sum_b0 <= sum_b0;
                    registered_sum_b1 <= sum_b1;
                    result_major <= product_major;
                    result_minor0 <= product_minor0;
                    result_pass1 <= pass1_phase;
                end
            end

            if (rounded_stage_ready) begin
                rounded_valid <= result_valid;
                if (result_valid) begin
                    registered_rounded_a0 <= rounded_a0;
                    registered_rounded_a1 <= rounded_a1;
                    registered_rounded_b0 <= rounded_b0;
                    registered_rounded_b1 <= rounded_b1;
                    rounded_major <= result_major;
                    rounded_minor0 <= result_minor0;
                    rounded_pass1 <= result_pass1;
                end
            end

            if (rounded_valid) begin
                if (rounded_pass1) begin
                    work_a[rounded_minor0 * 8 + rounded_major] <= clipped_a0;
                    work_a[(rounded_minor0 + 1'b1) * 8 + rounded_major] <= clipped_a1;
                    work_b[rounded_minor0 * 8 + rounded_major] <= clipped_b0;
                    work_b[(rounded_minor0 + 1'b1) * 8 + rounded_major] <= clipped_b1;
                end
                if (result_saturated)
                    saturated <= 1'b1;
            end

            if ((state == PASS1_DRAIN) && result_valid
                    && (result_minor0 == 3'd6)) begin
                if (result_major != 3'd7)
                    state <= PASS1_COLUMN;
            end
            if ((state == PASS1_DRAIN) && rounded_valid && rounded_pass1
                    && (rounded_minor0 == 3'd6)
                    && (rounded_major == 3'd7)) begin
                state <= PASS2;
                issue_count <= '0;
            end
            if (output_stage_ready && (!rounded_valid || !rounded_pass1)) begin
                m_valid <= rounded_valid && !rounded_pass1;
                if (rounded_valid && !rounded_pass1) begin
                    m_index <= {rounded_major, rounded_minor0};
                    m_a0 <= clipped_a0;
                    m_a1 <= clipped_a1;
                    m_b0 <= clipped_b0;
                    m_b1 <= clipped_b1;
                    m_last <= (rounded_major == 3'd7)
                           && (rounded_minor0 == 3'd6);
                end
            end

            if ((state == PASS2_DRAIN) && output_fire && m_last) begin
                m_valid <= 1'b0;
                state <= IDLE;
                done <= 1'b1;
            end
        end
    end
    /* verilator lint_on WIDTHEXPAND */
endmodule
