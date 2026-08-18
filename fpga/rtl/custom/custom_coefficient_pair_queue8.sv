module custom_coefficient_pair_queue8 (
    input  logic                 clk,
    input  logic                 rst_n,
    input  logic                 clear_error,

    input  logic                 pair_valid,
    output logic                 pair_ready,
    input  logic                 pair_table_id,
    input  logic [5:0]           pair_base_count,

    input  logic                 s_valid,
    output logic                 s_ready,
    input  logic [5:0]           s_index,
    input  logic signed [11:0]   s_a0,
    input  logic signed [11:0]   s_a1,
    input  logic signed [11:0]   s_b0,
    input  logic signed [11:0]   s_b1,

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

    output logic                 block_done,
    output logic                 pair_done,
    output logic                 busy,
    output logic                 coefficient_saturated,
    output logic                 input_error
);
    logic [3:0] bank_start_valid, bank_start_ready;
    logic [3:0] bank_s_valid, bank_s_ready;
    logic [3:0] bank_m_valid, bank_m_ready;
    logic [1:0] bank_m_op_type [0:3];
    logic bank_m_layer [0:3];
    logic bank_m_mandatory [0:3];
    logic [5:0] bank_m_reserve_release [0:3];
    logic bank_m_table_class [0:3];
    logic bank_m_table_id [0:3];
    logic [7:0] bank_m_symbol [0:3];
    logic [10:0] bank_m_amplitude [0:3];
    logic [3:0] bank_m_amplitude_length [0:3];
    logic bank_m_raw_value [0:3];
    logic [1:0] bank_m_raw_length [0:3];
    logic bank_m_eob_required [0:3];
    logic bank_m_last [0:3];
    logic [3:0] bank_done, bank_busy, bank_saturated, bank_input_error;
    logic signed [11:0] bank_s_coefficient [0:3];

    logic [3:0] bank_occupied;
    logic write_pair, active_input_pair;
    logic [1:0] read_bank;
    logic input_loading, odd_pending;
    logic [5:0] expected_index;
    logic signed [11:0] pending_a1, pending_b1;
    logic pair_fire, direct_fire, odd_fire;
    logic metadata_valid;
    logic [1:0] write_bank_a, write_bank_b;
    logic [1:0] active_bank_a, active_bank_b;

    assign write_bank_a = {write_pair, 1'b0};
    assign write_bank_b = {write_pair, 1'b1};
    assign active_bank_a = {active_input_pair, 1'b0};
    assign active_bank_b = {active_input_pair, 1'b1};
    assign metadata_valid = pair_base_count > 6'd1;
    assign pair_ready = !input_loading
                      && !bank_occupied[write_bank_a]
                      && !bank_occupied[write_bank_b]
                      && bank_start_ready[write_bank_a]
                      && bank_start_ready[write_bank_b];
    assign pair_fire = pair_valid && pair_ready;

    assign s_ready = input_loading && !odd_pending
                   && bank_s_ready[active_bank_a]
                   && bank_s_ready[active_bank_b];
    assign direct_fire = s_valid && s_ready;
    assign odd_fire = odd_pending
                    && bank_s_ready[active_bank_a]
                    && bank_s_ready[active_bank_b];

    assign m_valid = bank_occupied[read_bank] && bank_m_valid[read_bank];
    assign m_op_type = bank_m_op_type[read_bank];
    assign m_layer = bank_m_layer[read_bank];
    assign m_mandatory = bank_m_mandatory[read_bank];
    assign m_reserve_release = bank_m_reserve_release[read_bank];
    assign m_table_class = bank_m_table_class[read_bank];
    assign m_table_id = bank_m_table_id[read_bank];
    assign m_symbol = bank_m_symbol[read_bank];
    assign m_amplitude = bank_m_amplitude[read_bank];
    assign m_amplitude_length = bank_m_amplitude_length[read_bank];
    assign m_raw_value = bank_m_raw_value[read_bank];
    assign m_raw_length = bank_m_raw_length[read_bank];
    assign m_eob_required = bank_m_eob_required[read_bank];
    assign m_last = bank_m_last[read_bank];
    assign busy = input_loading || odd_pending || (bank_occupied != 0)
                || (bank_busy != 0);

    integer route_bank;
    always_comb begin
        bank_start_valid = '0;
        bank_s_valid = '0;
        bank_m_ready = '0;
        for (route_bank = 0; route_bank < 4; route_bank = route_bank + 1)
            bank_s_coefficient[route_bank] = '0;

        if (pair_fire && metadata_valid) begin
            bank_start_valid[write_bank_a] = 1'b1;
            bank_start_valid[write_bank_b] = 1'b1;
        end
        if (input_loading) begin
            if (odd_pending) begin
                bank_s_valid[active_bank_a] = 1'b1;
                bank_s_valid[active_bank_b] = 1'b1;
                bank_s_coefficient[active_bank_a] = pending_a1;
                bank_s_coefficient[active_bank_b] = pending_b1;
            end else begin
                bank_s_valid[active_bank_a] = s_valid;
                bank_s_valid[active_bank_b] = s_valid;
                bank_s_coefficient[active_bank_a] = s_a0;
                bank_s_coefficient[active_bank_b] = s_b0;
            end
        end
        bank_m_ready[read_bank] = m_ready && bank_occupied[read_bank];
    end

    genvar bank;
    generate
        for (bank = 0; bank < 4; bank = bank + 1) begin : scanners
            custom_coefficient_scanner8 scanner (
                .clk(clk), .rst_n(rst_n), .clear_error(clear_error),
                .start_valid(bank_start_valid[bank]),
                .start_ready(bank_start_ready[bank]),
                .table_id(pair_table_id), .base_count(pair_base_count),
                .s_valid(bank_s_valid[bank]), .s_ready(bank_s_ready[bank]),
                .s_coefficient(bank_s_coefficient[bank]),
                .m_valid(bank_m_valid[bank]), .m_ready(bank_m_ready[bank]),
                .m_op_type(bank_m_op_type[bank]),
                .m_layer(bank_m_layer[bank]),
                .m_mandatory(bank_m_mandatory[bank]),
                .m_reserve_release(bank_m_reserve_release[bank]),
                .m_table_class(bank_m_table_class[bank]),
                .m_table_id(bank_m_table_id[bank]),
                .m_symbol(bank_m_symbol[bank]),
                .m_amplitude(bank_m_amplitude[bank]),
                .m_amplitude_length(bank_m_amplitude_length[bank]),
                .m_raw_value(bank_m_raw_value[bank]),
                .m_raw_length(bank_m_raw_length[bank]),
                .m_eob_required(bank_m_eob_required[bank]),
                .m_last(bank_m_last[bank]), .done(bank_done[bank]),
                .busy(bank_busy[bank]),
                .coefficient_saturated(bank_saturated[bank]),
                .input_error(bank_input_error[bank])
            );
        end
    endgenerate

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bank_occupied <= '0;
            write_pair <= 1'b0;
            active_input_pair <= 1'b0;
            read_bank <= '0;
            input_loading <= 1'b0;
            odd_pending <= 1'b0;
            expected_index <= '0;
            pending_a1 <= '0;
            pending_b1 <= '0;
            block_done <= 1'b0;
            pair_done <= 1'b0;
            coefficient_saturated <= 1'b0;
            input_error <= 1'b0;
        end else begin
            block_done <= 1'b0;
            pair_done <= 1'b0;
            if (clear_error) begin
                bank_occupied <= '0;
                write_pair <= 1'b0;
                active_input_pair <= 1'b0;
                read_bank <= '0;
                input_loading <= 1'b0;
                odd_pending <= 1'b0;
                expected_index <= '0;
                coefficient_saturated <= 1'b0;
                input_error <= 1'b0;
            end else begin
                if (pair_fire) begin
                    if (metadata_valid) begin
                        bank_occupied[write_bank_a] <= 1'b1;
                        bank_occupied[write_bank_b] <= 1'b1;
                        active_input_pair <= write_pair;
                        input_loading <= 1'b1;
                        odd_pending <= 1'b0;
                        expected_index <= '0;
                        write_pair <= !write_pair;
                    end else begin
                        input_error <= 1'b1;
                    end
                end

                if (direct_fire) begin
                    pending_a1 <= s_a1;
                    pending_b1 <= s_b1;
                    odd_pending <= 1'b1;
                    if (s_index != expected_index || s_index[0])
                        input_error <= 1'b1;
                end
                if (odd_fire) begin
                    odd_pending <= 1'b0;
                    if (expected_index == 6'd62) begin
                        input_loading <= 1'b0;
                    end else begin
                        expected_index <= expected_index + 6'd2;
                    end
                end

                if (bank_done[read_bank]) begin
                    bank_occupied[read_bank] <= 1'b0;
                    read_bank <= read_bank + 1'b1;
                    block_done <= 1'b1;
                    if (read_bank[0])
                        pair_done <= 1'b1;
                end

                if (bank_input_error != 0)
                    input_error <= 1'b1;
                if (bank_saturated != 0)
                    coefficient_saturated <= 1'b1;
            end
        end
    end
endmodule
