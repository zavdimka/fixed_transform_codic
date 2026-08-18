module custom_coefficient_pingpong8 (
    input  logic                 clk,
    input  logic                 rst_n,
    input  logic                 clear_error,

    input  logic                 block_valid,
    output logic                 block_ready,
    input  logic                 block_table_id,
    input  logic [5:0]           block_base_count,

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

    output logic                 block_done,
    output logic                 busy,
    output logic                 coefficient_saturated,
    output logic                 input_error
);

    logic [1:0] bank_start_valid, bank_start_ready;
    logic [1:0] bank_s_valid, bank_s_ready;
    logic [1:0] bank_m_valid, bank_m_ready;
    logic [3:0] bank_m_op_type;
    logic [1:0] bank_m_layer, bank_m_mandatory, bank_m_table_class;
    logic [1:0] bank_m_table_id, bank_m_raw_value, bank_m_eob_required;
    logic [1:0] bank_m_last, bank_done, bank_busy;
    logic [1:0] bank_saturated, bank_input_error;
    logic [11:0] bank_m_reserve_release;
    logic [15:0] bank_m_symbol;
    logic [21:0] bank_m_amplitude;
    logic [7:0] bank_m_amplitude_length;
    logic [3:0] bank_m_raw_length;

    logic [1:0] bank_occupied;
    logic write_bank, read_bank, active_input_bank;
    logic input_loading;
    logic [5:0] input_index;
    logic block_fire, coefficient_fire;
    logic metadata_valid;

    assign metadata_valid = block_base_count > 1;
    assign block_ready = !input_loading && !bank_occupied[write_bank]
                       && bank_start_ready[write_bank];
    assign block_fire = block_valid && block_ready;

    assign bank_start_valid[0] = block_fire && metadata_valid && !write_bank;
    assign bank_start_valid[1] = block_fire && metadata_valid && write_bank;
    assign bank_s_valid[0] = s_valid && input_loading && !active_input_bank;
    assign bank_s_valid[1] = s_valid && input_loading && active_input_bank;
    assign s_ready = input_loading && bank_s_ready[active_input_bank];
    assign coefficient_fire = s_valid && s_ready;

    assign bank_m_ready[0] = m_ready && bank_occupied[0] && !read_bank;
    assign bank_m_ready[1] = m_ready && bank_occupied[1] && read_bank;
    assign m_valid = bank_occupied[read_bank] && bank_m_valid[read_bank];
    assign m_op_type = read_bank ? bank_m_op_type[3:2] : bank_m_op_type[1:0];
    assign m_layer = bank_m_layer[read_bank];
    assign m_mandatory = bank_m_mandatory[read_bank];
    assign m_reserve_release = read_bank
                             ? bank_m_reserve_release[11:6]
                             : bank_m_reserve_release[5:0];
    assign m_table_class = bank_m_table_class[read_bank];
    assign m_table_id = bank_m_table_id[read_bank];
    assign m_symbol = read_bank ? bank_m_symbol[15:8] : bank_m_symbol[7:0];
    assign m_amplitude = read_bank
                       ? bank_m_amplitude[21:11] : bank_m_amplitude[10:0];
    assign m_amplitude_length = read_bank
                              ? bank_m_amplitude_length[7:4]
                              : bank_m_amplitude_length[3:0];
    assign m_raw_value = bank_m_raw_value[read_bank];
    assign m_raw_length = read_bank
                        ? bank_m_raw_length[3:2] : bank_m_raw_length[1:0];
    assign m_eob_required = bank_m_eob_required[read_bank];
    assign m_last = bank_m_last[read_bank];

    assign busy = input_loading || (bank_occupied != 0) || (bank_busy != 0);

    genvar bank;
    generate
        for (bank = 0; bank < 2; bank = bank + 1) begin : scanners
            custom_coefficient_scanner8 scanner (
                .clk(clk),
                .rst_n(rst_n),
                .clear_error(clear_error),
                .start_valid(bank_start_valid[bank]),
                .start_ready(bank_start_ready[bank]),
                .table_id(block_table_id),
                .base_count(block_base_count),
                .s_valid(bank_s_valid[bank]),
                .s_ready(bank_s_ready[bank]),
                .s_coefficient(s_coefficient),
                .m_valid(bank_m_valid[bank]),
                .m_ready(bank_m_ready[bank]),
                .m_op_type(bank_m_op_type[bank*2 +: 2]),
                .m_layer(bank_m_layer[bank]),
                .m_mandatory(bank_m_mandatory[bank]),
                .m_reserve_release(bank_m_reserve_release[bank*6 +: 6]),
                .m_table_class(bank_m_table_class[bank]),
                .m_table_id(bank_m_table_id[bank]),
                .m_symbol(bank_m_symbol[bank*8 +: 8]),
                .m_amplitude(bank_m_amplitude[bank*11 +: 11]),
                .m_amplitude_length(bank_m_amplitude_length[bank*4 +: 4]),
                .m_raw_value(bank_m_raw_value[bank]),
                .m_raw_length(bank_m_raw_length[bank*2 +: 2]),
                .m_eob_required(bank_m_eob_required[bank]),
                .m_last(bank_m_last[bank]),
                .done(bank_done[bank]),
                .busy(bank_busy[bank]),
                .coefficient_saturated(bank_saturated[bank]),
                .input_error(bank_input_error[bank])
            );
        end
    endgenerate

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bank_occupied <= 0;
            write_bank <= 1'b0;
            read_bank <= 1'b0;
            active_input_bank <= 1'b0;
            input_loading <= 1'b0;
            input_index <= 0;
            block_done <= 1'b0;
            coefficient_saturated <= 1'b0;
            input_error <= 1'b0;
        end else begin
            block_done <= 1'b0;
            if (clear_error) begin
                bank_occupied <= 0;
                write_bank <= 1'b0;
                read_bank <= 1'b0;
                active_input_bank <= 1'b0;
                input_loading <= 1'b0;
                input_index <= 0;
                coefficient_saturated <= 1'b0;
                input_error <= 1'b0;
            end

            if (block_fire) begin
                if (metadata_valid) begin
                    bank_occupied[write_bank] <= 1'b1;
                    active_input_bank <= write_bank;
                    input_loading <= 1'b1;
                    input_index <= 0;
                    write_bank <= !write_bank;
                end else begin
                    input_error <= 1'b1;
                end
            end

            if (coefficient_fire) begin
                if (input_index == 63) begin
                    input_loading <= 1'b0;
                end else begin
                    input_index <= input_index + 1'b1;
                end
            end

            if (bank_done[read_bank]) begin
                bank_occupied[read_bank] <= 1'b0;
                read_bank <= !read_bank;
                block_done <= 1'b1;
            end

            if ((bank_input_error != 0) && !clear_error)
                input_error <= 1'b1;
            if ((bank_saturated != 0) && !clear_error)
                coefficient_saturated <= 1'b1;
        end
    end

endmodule
