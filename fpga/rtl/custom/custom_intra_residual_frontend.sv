module custom_intra_residual_frontend (
    input  logic                       clk,
    input  logic                       rst_n,

    input  logic                       start_valid,
    output logic                       start_ready,
    input  logic                       has_left,
    input  logic [127:0]               left_y,
    input  logic [63:0]                left_cb,
    input  logic [63:0]                left_cr,

    // Fixed input order: 16 Y rows, eight Cb rows, then eight Cr rows.
    input  logic                       s_valid,
    output logic                       s_ready,
    input  logic [127:0]               s_row,

    output logic                       prefix_valid,
    input  logic                       prefix_ready,
    output logic [1:0]                 prefix_mode,

    output logic                       command_valid,
    input  logic                       command_ready,
    output logic [1:0]                 command_pair,

    output logic                       m_valid,
    input  logic                       m_ready,
    output logic signed [127:0]        m_row_a,
    output logic signed [127:0]        m_row_b,
    output logic                       m_last,

    output logic [31:0]                dc_satd,
    output logic [31:0]                horizontal_satd,
    output logic                       done,
    output logic                       busy,
    output logic                       protocol_error
);
    typedef enum logic [2:0] {
        IDLE, LOAD_ROWS, ISSUE_SATD, DRAIN_SATD,
        SEND_PREFIX, SEND_COMMAND, EMIT_ROWS
    } state_t;
    state_t state;

    logic [127:0] y_rows [0:15];
    logic [63:0] cb_rows [0:7];
    logic [63:0] cr_rows [0:7];
    logic [127:0] group_rows [0:3];
    logic [127:0] active_left_y;
    logic [63:0] active_left_cb, active_left_cr;
    logic active_has_left;
    logic [7:0] dc_y, dc_cb, dc_cr;

    logic [5:0] load_index;
    logic [1:0] group_row;
    logic [1:0] group_plane;
    logic [3:0] group_row_base;
    logic [2:0] blocks_in_group;
    logic [2:0] issue_block;
    logic issue_horizontal;
    logic [3:0] expected_results, returned_results;

    logic satd_s_valid, satd_s_tag, satd_m_valid, satd_m_tag;
    logic signed [143:0] satd_s_samples;
    logic [15:0] satd_m_value;

    logic [1:0] pair_index;
    logic [3:0] rows_issued;
    logic read_pending;
    logic read_last;
    logic [3:0] read_absolute_row;
    logic [127:0] read_y_word;
    logic [63:0] read_cb_word, read_cr_word;
    integer lane;
    integer sample_row, sample_column;
    integer reference_address [0:3];
    logic [7:0] active_dc;
    logic [7:0] active_left [0:3];
    logic [7:0] predictor_sample;
    logic signed [8:0] residual_sample;
    logic [31:0] dc_total_next, horizontal_total_next;

    function automatic logic [7:0] average16(input logic [127:0] values);
        logic [8:0] pair_sum [0:7];
        logic [9:0] quad_sum [0:3];
        logic [10:0] octet_sum [0:1];
        logic [11:0] sum;
        begin
            pair_sum[0] = {1'b0, values[7:0]} + {1'b0, values[15:8]};
            pair_sum[1] = {1'b0, values[23:16]} + {1'b0, values[31:24]};
            pair_sum[2] = {1'b0, values[39:32]} + {1'b0, values[47:40]};
            pair_sum[3] = {1'b0, values[55:48]} + {1'b0, values[63:56]};
            pair_sum[4] = {1'b0, values[71:64]} + {1'b0, values[79:72]};
            pair_sum[5] = {1'b0, values[87:80]} + {1'b0, values[95:88]};
            pair_sum[6] = {1'b0, values[103:96]} + {1'b0, values[111:104]};
            pair_sum[7] = {1'b0, values[119:112]} + {1'b0, values[127:120]};
            quad_sum[0] = pair_sum[0] + pair_sum[1];
            quad_sum[1] = pair_sum[2] + pair_sum[3];
            quad_sum[2] = pair_sum[4] + pair_sum[5];
            quad_sum[3] = pair_sum[6] + pair_sum[7];
            octet_sum[0] = quad_sum[0] + quad_sum[1];
            octet_sum[1] = quad_sum[2] + quad_sum[3];
            sum = octet_sum[0] + octet_sum[1] + 12'd8;
            average16 = sum[11:4];
        end
    endfunction

    function automatic logic [7:0] average8(input logic [63:0] values);
        logic [8:0] pair_sum [0:3];
        logic [9:0] quad_sum [0:1];
        logic [11:0] sum;
        begin
            pair_sum[0] = {1'b0, values[7:0]} + {1'b0, values[15:8]};
            pair_sum[1] = {1'b0, values[23:16]} + {1'b0, values[31:24]};
            pair_sum[2] = {1'b0, values[39:32]} + {1'b0, values[47:40]};
            pair_sum[3] = {1'b0, values[55:48]} + {1'b0, values[63:56]};
            quad_sum[0] = pair_sum[0] + pair_sum[1];
            quad_sum[1] = pair_sum[2] + pair_sum[3];
            sum = {2'b0, quad_sum[0]} + {2'b0, quad_sum[1]} + 12'd4;
            average8 = sum[10:3];
        end
    endfunction

    function automatic logic signed [15:0] residual16(
        input logic [7:0] source,
        input logic [7:0] prediction
    );
        logic signed [8:0] difference;
        begin
            difference = $signed({1'b0, source})
                       - $signed({1'b0, prediction});
            residual16 = {{7{difference[8]}}, difference};
        end
    endfunction

    assign start_ready = state == IDLE;
    assign s_ready = state == LOAD_ROWS;
    assign prefix_valid = state == SEND_PREFIX;
    assign command_valid = state == SEND_COMMAND;
    assign command_pair = pair_index;
    assign busy = state != IDLE;
    assign satd_s_valid = state == ISSUE_SATD;
    assign satd_s_tag = issue_horizontal;

    always_comb begin
        case (group_plane)
            2'd0: active_dc = dc_y;
            2'd1: active_dc = dc_cb;
            default: active_dc = dc_cr;
        endcase
        for (sample_row = 0; sample_row < 4; sample_row = sample_row + 1) begin
            reference_address[sample_row] = sample_row
                + {28'b0, group_row_base};
            case (group_plane)
                2'd0: active_left[sample_row] = active_left_y[
                    reference_address[sample_row] * 8 +: 8];
                2'd1: active_left[sample_row] = active_left_cb[
                    reference_address[sample_row] * 8 +: 8];
                default: active_left[sample_row] = active_left_cr[
                    reference_address[sample_row] * 8 +: 8];
            endcase
        end

        satd_s_samples = '0;
        for (sample_row = 0; sample_row < 4; sample_row = sample_row + 1) begin
            for (sample_column = 0; sample_column < 4;
                 sample_column = sample_column + 1) begin
                predictor_sample = issue_horizontal
                    ? active_left[sample_row] : active_dc;
                residual_sample = $signed({1'b0, group_rows[sample_row][
                    (issue_block * 4 + sample_column) * 8 +: 8]})
                    - $signed({1'b0, predictor_sample});
                satd_s_samples[(sample_row * 4 + sample_column) * 9 +: 9]
                    = residual_sample;
            end
        end

        dc_total_next = dc_satd;
        horizontal_total_next = horizontal_satd;
        if (satd_m_valid) begin
            if (satd_m_tag)
                horizontal_total_next = horizontal_satd
                    + {16'b0, satd_m_value};
            else
                dc_total_next = dc_satd + {16'b0, satd_m_value};
        end
    end

    custom_satd4x4 satd (
        .clk(clk), .rst_n(rst_n),
        .s_valid(satd_s_valid), .s_tag(satd_s_tag),
        .s_samples(satd_s_samples),
        .m_valid(satd_m_valid), .m_tag(satd_m_tag), .m_satd(satd_m_value)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            active_has_left <= 1'b0;
            active_left_y <= '0;
            active_left_cb <= '0;
            active_left_cr <= '0;
            dc_y <= 8'd128;
            dc_cb <= 8'd128;
            dc_cr <= 8'd128;
            load_index <= '0;
            group_row <= '0;
            group_plane <= '0;
            group_row_base <= '0;
            blocks_in_group <= '0;
            issue_block <= '0;
            issue_horizontal <= 1'b0;
            expected_results <= '0;
            returned_results <= '0;
            prefix_mode <= '0;
            pair_index <= '0;
            rows_issued <= '0;
            read_pending <= 1'b0;
            read_last <= 1'b0;
            read_absolute_row <= '0;
            read_y_word <= '0;
            read_cb_word <= '0;
            read_cr_word <= '0;
            m_valid <= 1'b0;
            m_row_a <= '0;
            m_row_b <= '0;
            m_last <= 1'b0;
            dc_satd <= '0;
            horizontal_satd <= '0;
            done <= 1'b0;
            protocol_error <= 1'b0;
            for (lane = 0; lane < 4; lane = lane + 1)
                group_rows[lane] <= '0;
        end else begin
            done <= 1'b0;

            if (state == IDLE && start_valid) begin
                state <= LOAD_ROWS;
                active_has_left <= has_left;
                active_left_y <= left_y;
                active_left_cb <= left_cb;
                active_left_cr <= left_cr;
                dc_y <= has_left ? average16(left_y) : 8'd128;
                dc_cb <= has_left ? average8(left_cb) : 8'd128;
                dc_cr <= has_left ? average8(left_cr) : 8'd128;
                load_index <= '0;
                group_row <= '0;
                dc_satd <= '0;
                horizontal_satd <= '0;
                prefix_mode <= '0;
                pair_index <= '0;
                read_pending <= 1'b0;
                m_valid <= 1'b0;
                protocol_error <= 1'b0;
            end

            if (state == LOAD_ROWS && s_valid) begin
                group_rows[group_row] <= s_row;
                if (load_index < 16)
                    y_rows[load_index[3:0]] <= s_row;
                else if (load_index < 24)
                    cb_rows[load_index[2:0]] <= s_row[63:0];
                else if (load_index < 32)
                    cr_rows[load_index[2:0]] <= s_row[63:0];
                else
                    protocol_error <= 1'b1;

                if (group_row == 3) begin
                    group_plane <= load_index < 16 ? 2'd0
                                 : load_index < 24 ? 2'd1 : 2'd2;
                    if (load_index < 16)
                        group_row_base <= {load_index[3:2], 2'b00};
                    else
                        group_row_base <= {1'b0, load_index[2], 2'b00};
                    blocks_in_group <= load_index < 16 ? 3'd4 : 3'd2;
                    issue_block <= '0;
                    issue_horizontal <= 1'b0;
                    expected_results <= (load_index < 16 ? 4'd4 : 4'd2)
                        << active_has_left;
                    returned_results <= '0;
                    group_row <= '0;
                    state <= ISSUE_SATD;
                end else begin
                    group_row <= group_row + 1'b1;
                end
                if (load_index < 31)
                    load_index <= load_index + 1'b1;
            end

            if (state == ISSUE_SATD) begin
                if (active_has_left && !issue_horizontal) begin
                    issue_horizontal <= 1'b1;
                end else begin
                    issue_horizontal <= 1'b0;
                    if (issue_block + 1'b1 == blocks_in_group)
                        state <= DRAIN_SATD;
                    else
                        issue_block <= issue_block + 1'b1;
                end
            end

            if (satd_m_valid) begin
                dc_satd <= dc_total_next;
                horizontal_satd <= horizontal_total_next;
                returned_results <= returned_results + 1'b1;
                if (state == DRAIN_SATD &&
                    returned_results + 1'b1 == expected_results) begin
                    if (load_index == 31) begin
                        prefix_mode <= active_has_left &&
                            (horizontal_total_next < dc_total_next) ? 2'd2 : 2'd0;
                        state <= SEND_PREFIX;
                    end else begin
                        state <= LOAD_ROWS;
                    end
                end
            end

            if (state == SEND_PREFIX && prefix_ready) begin
                pair_index <= '0;
                state <= SEND_COMMAND;
            end

            if (state == SEND_COMMAND && command_ready) begin
                rows_issued <= '0;
                read_pending <= 1'b0;
                m_valid <= 1'b0;
                state <= EMIT_ROWS;
            end

            if (state == EMIT_ROWS) begin
                if (m_valid && m_ready) begin
                    m_valid <= 1'b0;
                    m_last <= 1'b0;
                    if (m_last) begin
                        if (pair_index == 2) begin
                            state <= IDLE;
                            done <= 1'b1;
                        end else begin
                            pair_index <= pair_index + 1'b1;
                            state <= SEND_COMMAND;
                        end
                    end
                end

                if (!read_pending && rows_issued < 8 &&
                    (!m_valid || m_ready)) begin
                    if (pair_index < 2) begin
                        read_y_word <= y_rows[
                            rows_issued + (pair_index == 1 ? 8 : 0)];
                        read_absolute_row <= rows_issued
                            + (pair_index == 1 ? 8 : 0);
                    end else begin
                        read_cb_word <= cb_rows[rows_issued[2:0]];
                        read_cr_word <= cr_rows[rows_issued[2:0]];
                        read_absolute_row <= rows_issued;
                    end
                    read_last <= rows_issued == 7;
                    read_pending <= 1'b1;
                    rows_issued <= rows_issued + 1'b1;
                end else if (read_pending && (!m_valid || m_ready)) begin
                    for (lane = 0; lane < 8; lane = lane + 1) begin
                        if (pair_index < 2) begin
                            m_row_a[lane * 16 +: 16] <= residual16(
                                read_y_word[lane * 8 +: 8],
                                prefix_mode == 2 ? active_left_y[
                                    read_absolute_row * 8 +: 8] : dc_y);
                            m_row_b[lane * 16 +: 16] <= residual16(
                                read_y_word[(lane + 8) * 8 +: 8],
                                prefix_mode == 2 ? active_left_y[
                                    read_absolute_row * 8 +: 8] : dc_y);
                        end else begin
                            m_row_a[lane * 16 +: 16] <= residual16(
                                read_cb_word[lane * 8 +: 8],
                                prefix_mode == 2 ? active_left_cb[
                                    read_absolute_row * 8 +: 8] : dc_cb);
                            m_row_b[lane * 16 +: 16] <= residual16(
                                read_cr_word[lane * 8 +: 8],
                                prefix_mode == 2 ? active_left_cr[
                                    read_absolute_row * 8 +: 8] : dc_cr);
                        end
                    end
                    m_valid <= 1'b1;
                    m_last <= read_last;
                    read_pending <= 1'b0;
                end
            end
        end
    end
endmodule
