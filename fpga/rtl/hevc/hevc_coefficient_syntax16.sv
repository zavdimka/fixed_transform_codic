module hevc_coefficient_syntax16 (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               s_valid,
    output logic               s_ready,
    input  logic [7:0]         s_raster_address,
    input  logic signed [15:0] s_coefficient,
    input  logic               s_block_last,

    output logic               m_valid,
    input  logic               m_ready,
    output logic               m_bin,
    output logic               m_bypass,
    output logic [1:0]         m_source,
    output logic [1:0]         m_level_kind,
    output logic [4:0]         m_context_index,
    output logic               m_last_axis_y,
    output logic               m_significance_coded_sub_block,
    output logic [7:0]         m_scan_position,
    output logic [3:0]         m_group_scan_position,
    output logic [3:0]         m_coefficient_index,

    output logic               block_done,
    output logic               any_nonzero,
    output logic [7:0]         last_nonzero_scan_position,
    output logic [15:0]        significant_group_flags,
    output logic               busy,
    output logic               input_error
);
    typedef enum logic [3:0] {
        LOAD, START_SYNTAX, WAIT_LAST,
        SIGNIFICANCE_INIT, SIGNIFICANCE_READ,
        LEVEL_INIT, LEVEL_READ, WAIT_FINISH, RELEASE
    } state_t;
    state_t state;

    logic [15:0] group_nonzero;

    logic store_block_valid;
    logic store_block_ready;
    logic unused_store_block_bank;
    logic store_block_any_nonzero;
    logic [7:0] store_block_last_position;
    logic [15:0] store_block_group_flags;
    logic store_block_input_error;
    logic unused_store_read_active;
    logic store_release_valid;
    logic store_release_ready;

    logic [7:0] issue_position;
    logic issue_complete;
    logic read_pending;
    logic signed [15:0] ram_read_data;
    logic [7:0] pending_raster_address;
    logic [7:0] pending_scan_position;
    logic scan_valid;
    logic signed [15:0] scan_coefficient;
    logic scan_nonzero;
    logic [7:0] scan_raster_address;
    logic [7:0] scan_position;

    logic last_s_valid;
    logic last_s_ready;
    logic last_m_valid;
    logic last_m_ready;
    logic last_m_bin;
    logic last_m_bypass;
    logic last_m_axis_y;
    logic [3:0] last_m_context_index;
    logic last_m_syntax_last;

    logic significance_s_ready;
    logic significance_m_valid;
    logic significance_m_ready;
    logic significance_m_bin;
    logic significance_m_coded_sub_block;
    logic [4:0] significance_m_context_index;
    logic [7:0] significance_m_scan_position;
    logic significance_stage_done;
    logic significance_input_error;

    logic level_s_ready;
    logic level_m_valid;
    logic level_m_ready;
    logic level_m_bin;
    logic level_m_bypass;
    logic [1:0] level_m_kind;
    logic [4:0] level_m_context_index;
    logic [3:0] level_m_group_scan_position;
    logic [3:0] level_m_coefficient_index;
    logic level_block_done;
    logic level_input_error;

    logic arbiter_start_valid;
    logic arbiter_start_ready;
    logic arbiter_block_done;
    logic arbiter_finished;
    logic arbiter_m_valid;
    logic arbiter_m_ready;
    logic arbiter_m_bin;
    logic arbiter_m_bypass;
    logic [1:0] arbiter_m_source;
    logic [1:0] arbiter_m_level_kind;
    logic [4:0] arbiter_m_context_index;
    logic arbiter_m_last_axis_y;
    logic arbiter_m_significance_coded_sub_block;
    logic [7:0] arbiter_m_scan_position;
    logic [3:0] arbiter_m_group_scan_position;
    logic [3:0] arbiter_m_coefficient_index;

    logic [1:0] fifo_count;
    logic fifo_write_pointer;
    logic fifo_read_pointer;
    logic fifo_bin [0:1];
    logic fifo_bypass [0:1];
    logic [1:0] fifo_source [0:1];
    logic [1:0] fifo_level_kind [0:1];
    logic [4:0] fifo_context_index [0:1];
    logic fifo_last_axis_y [0:1];
    logic fifo_significance_coded_sub_block [0:1];
    logic [7:0] fifo_scan_position [0:1];
    logic [3:0] fifo_group_scan_position [0:1];
    logic [3:0] fifo_coefficient_index [0:1];

    logic unused_last_busy;
    logic unused_significance_syntax_last;
    logic unused_significance_busy;
    logic unused_level_group_done;
    logic unused_level_busy;
    logic unused_arbiter_busy;

    function automatic logic [3:0] diagonal4(input logic [3:0] index);
        case (index)
            4'd0: diagonal4 = 4'd0;
            4'd1: diagonal4 = 4'd4;
            4'd2: diagonal4 = 4'd1;
            4'd3: diagonal4 = 4'd8;
            4'd4: diagonal4 = 4'd5;
            4'd5: diagonal4 = 4'd2;
            4'd6: diagonal4 = 4'd12;
            4'd7: diagonal4 = 4'd9;
            4'd8: diagonal4 = 4'd6;
            4'd9: diagonal4 = 4'd3;
            4'd10: diagonal4 = 4'd13;
            4'd11: diagonal4 = 4'd10;
            4'd12: diagonal4 = 4'd7;
            4'd13: diagonal4 = 4'd14;
            4'd14: diagonal4 = 4'd11;
            default: diagonal4 = 4'd15;
        endcase
    endfunction

    function automatic logic [7:0] scan_to_raster(
        input logic [7:0] position
    );
        logic [3:0] group_raster;
        logic [3:0] local_raster;
        begin
            group_raster = diagonal4(position[7:4]);
            local_raster = diagonal4(position[3:0]);
            scan_to_raster = {
                group_raster[3:2], local_raster[3:2],
                group_raster[1:0], local_raster[1:0]
            };
        end
    endfunction

    wire reader_active = (state == SIGNIFICANCE_READ) ||
                         (state == LEVEL_READ);
    wire reader_ready = (state == SIGNIFICANCE_READ) ?
                        significance_s_ready : level_s_ready;
    wire reader_advance = !scan_valid || reader_ready;
    wire ram_read_enable = reader_active && reader_advance &&
                           !issue_complete;
    wire [7:0] ram_read_address = scan_to_raster(issue_position);
    wire scan_group_nonzero = group_nonzero[
        diagonal4(scan_position[7:4])
    ];
    wire last_final_fire = last_m_valid && last_m_ready &&
                           last_m_syntax_last;
    wire atomic_start_ready = last_s_ready && arbiter_start_ready;

    assign busy = (state != LOAD);
    assign significant_group_flags = group_nonzero;
    assign store_block_ready = (state == LOAD);
    assign store_release_valid = (state == RELEASE);
    assign last_s_valid = (state == START_SYNTAX) && atomic_start_ready;
    assign arbiter_start_valid = last_s_valid;

    assign arbiter_m_ready = (fifo_count < 2);
    assign m_valid = (fifo_count != 0);
    assign m_bin = fifo_bin[fifo_read_pointer];
    assign m_bypass = fifo_bypass[fifo_read_pointer];
    assign m_source = fifo_source[fifo_read_pointer];
    assign m_level_kind = fifo_level_kind[fifo_read_pointer];
    assign m_context_index = fifo_context_index[fifo_read_pointer];
    assign m_last_axis_y = fifo_last_axis_y[fifo_read_pointer];
    assign m_significance_coded_sub_block =
        fifo_significance_coded_sub_block[fifo_read_pointer];
    assign m_scan_position = fifo_scan_position[fifo_read_pointer];
    assign m_group_scan_position =
        fifo_group_scan_position[fifo_read_pointer];
    assign m_coefficient_index =
        fifo_coefficient_index[fifo_read_pointer];

    wire fifo_enqueue = arbiter_m_valid && arbiter_m_ready;
    wire fifo_dequeue = m_valid && m_ready;

    hevc_coefficient_pingpong16 coefficient_store (
        .clk(clk),
        .rst_n(rst_n),
        .s_valid(s_valid),
        .s_ready(s_ready),
        .s_raster_address(s_raster_address),
        .s_coefficient(s_coefficient),
        .s_block_last(s_block_last),
        .block_valid(store_block_valid),
        .block_ready(store_block_ready),
        .block_bank(unused_store_block_bank),
        .block_any_nonzero(store_block_any_nonzero),
        .block_last_nonzero_scan_position(store_block_last_position),
        .block_significant_group_flags(store_block_group_flags),
        .block_input_error(store_block_input_error),
        .read_enable(ram_read_enable),
        .read_address(ram_read_address),
        .read_data(ram_read_data),
        .read_active(unused_store_read_active),
        .release_valid(store_release_valid),
        .release_ready(store_release_ready)
    );

    hevc_last_sig_bins16 last_significant (
        .clk(clk),
        .rst_n(rst_n),
        .s_valid(last_s_valid),
        .s_ready(last_s_ready),
        .s_raster_address(scan_to_raster(last_nonzero_scan_position)),
        .m_valid(last_m_valid),
        .m_ready(last_m_ready),
        .m_bin(last_m_bin),
        .m_bypass(last_m_bypass),
        .m_axis_y(last_m_axis_y),
        .m_context_index(last_m_context_index),
        .m_syntax_last(last_m_syntax_last),
        .busy(unused_last_busy)
    );

    hevc_significance_bins16 significance (
        .clk(clk),
        .rst_n(rst_n),
        .s_valid((state == SIGNIFICANCE_READ) && scan_valid),
        .s_ready(significance_s_ready),
        .s_raster_address((state == SIGNIFICANCE_READ) ?
            scan_raster_address : 8'd0),
        .s_scan_position((state == SIGNIFICANCE_READ) ?
            scan_position : 8'd0),
        .s_coefficient((state == SIGNIFICANCE_READ) ?
            scan_coefficient : 16'sd0),
        .s_group_nonzero((state == SIGNIFICANCE_READ) &&
            scan_group_nonzero),
        .s_significant_group_flags(group_nonzero),
        .s_block_last(scan_position == 0),
        .m_valid(significance_m_valid),
        .m_ready(significance_m_ready),
        .m_bin(significance_m_bin),
        .m_coded_sub_block(significance_m_coded_sub_block),
        .m_context_index(significance_m_context_index),
        .m_scan_position(significance_m_scan_position),
        .m_syntax_last(unused_significance_syntax_last),
        .stage_done(significance_stage_done),
        .busy(unused_significance_busy),
        .input_error(significance_input_error)
    );

    hevc_coefficient_level_bins16 levels (
        .clk(clk),
        .rst_n(rst_n),
        .s_valid((state == LEVEL_READ) && scan_valid),
        .s_ready(level_s_ready),
        .s_coefficient((state == LEVEL_READ) ?
            scan_coefficient : 16'sd0),
        .s_nonzero((state == LEVEL_READ) && scan_nonzero),
        .s_group_scan_position((state == LEVEL_READ) ?
            scan_position[7:4] : 4'd0),
        .s_block_start((state == LEVEL_READ) &&
            scan_position == last_nonzero_scan_position),
        .s_group_end((state == LEVEL_READ) &&
            scan_position[3:0] == 0),
        .s_block_last((state == LEVEL_READ) && scan_position == 0),
        .m_valid(level_m_valid),
        .m_ready(level_m_ready),
        .m_bin(level_m_bin),
        .m_bypass(level_m_bypass),
        .m_kind(level_m_kind),
        .m_context_index(level_m_context_index),
        .m_group_scan_position(level_m_group_scan_position),
        .m_coefficient_index(level_m_coefficient_index),
        .group_done(unused_level_group_done),
        .block_done(level_block_done),
        .busy(unused_level_busy),
        .input_error(level_input_error)
    );

    hevc_coefficient_syntax_arbiter16 arbiter (
        .clk(clk),
        .rst_n(rst_n),
        .s_start_valid(arbiter_start_valid),
        .s_start_ready(arbiter_start_ready),
        .s_last_valid(last_m_valid),
        .s_last_ready(last_m_ready),
        .s_last_bin(last_m_bin),
        .s_last_bypass(last_m_bypass),
        .s_last_axis_y(last_m_axis_y),
        .s_last_context_index(last_m_context_index),
        .s_last_syntax_last(last_m_syntax_last),
        .s_significance_valid(significance_m_valid),
        .s_significance_ready(significance_m_ready),
        .s_significance_bin(significance_m_bin),
        .s_significance_coded_sub_block(
            significance_m_coded_sub_block
        ),
        .s_significance_context_index(significance_m_context_index),
        .s_significance_scan_position(significance_m_scan_position),
        .s_significance_done(significance_stage_done),
        .s_level_valid(level_m_valid),
        .s_level_ready(level_m_ready),
        .s_level_bin(level_m_bin),
        .s_level_bypass(level_m_bypass),
        .s_level_kind(level_m_kind),
        .s_level_context_index(level_m_context_index),
        .s_level_group_scan_position(level_m_group_scan_position),
        .s_level_coefficient_index(level_m_coefficient_index),
        .s_level_done(level_block_done),
        .m_valid(arbiter_m_valid),
        .m_ready(arbiter_m_ready),
        .m_bin(arbiter_m_bin),
        .m_bypass(arbiter_m_bypass),
        .m_source(arbiter_m_source),
        .m_level_kind(arbiter_m_level_kind),
        .m_context_index(arbiter_m_context_index),
        .m_last_axis_y(arbiter_m_last_axis_y),
        .m_significance_coded_sub_block(
            arbiter_m_significance_coded_sub_block
        ),
        .m_scan_position(arbiter_m_scan_position),
        .m_group_scan_position(arbiter_m_group_scan_position),
        .m_coefficient_index(arbiter_m_coefficient_index),
        .block_done(arbiter_block_done),
        .busy(unused_arbiter_busy)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            fifo_count <= 2'd0;
            fifo_write_pointer <= 1'b0;
            fifo_read_pointer <= 1'b0;
        end else begin
            case ({fifo_enqueue, fifo_dequeue})
                2'b10: fifo_count <= fifo_count + 1'b1;
                2'b01: fifo_count <= fifo_count - 1'b1;
                default: fifo_count <= fifo_count;
            endcase
            if (fifo_enqueue) begin
                fifo_bin[fifo_write_pointer] <= arbiter_m_bin;
                fifo_bypass[fifo_write_pointer] <= arbiter_m_bypass;
                fifo_source[fifo_write_pointer] <= arbiter_m_source;
                fifo_level_kind[fifo_write_pointer] <=
                    arbiter_m_level_kind;
                fifo_context_index[fifo_write_pointer] <=
                    arbiter_m_context_index;
                fifo_last_axis_y[fifo_write_pointer] <=
                    arbiter_m_last_axis_y;
                fifo_significance_coded_sub_block[fifo_write_pointer] <=
                    arbiter_m_significance_coded_sub_block;
                fifo_scan_position[fifo_write_pointer] <=
                    arbiter_m_scan_position;
                fifo_group_scan_position[fifo_write_pointer] <=
                    arbiter_m_group_scan_position;
                fifo_coefficient_index[fifo_write_pointer] <=
                    arbiter_m_coefficient_index;
                fifo_write_pointer <= !fifo_write_pointer;
            end
            if (fifo_dequeue) begin
                fifo_read_pointer <= !fifo_read_pointer;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= LOAD;
            group_nonzero <= 16'd0;
            any_nonzero <= 1'b0;
            last_nonzero_scan_position <= 8'd0;
            issue_position <= 8'd0;
            issue_complete <= 1'b0;
            read_pending <= 1'b0;
            pending_raster_address <= 8'd0;
            pending_scan_position <= 8'd0;
            scan_valid <= 1'b0;
            scan_coefficient <= 16'sd0;
            scan_nonzero <= 1'b0;
            scan_raster_address <= 8'd0;
            scan_position <= 8'd0;
            block_done <= 1'b0;
            input_error <= 1'b0;
            arbiter_finished <= 1'b0;
        end else begin
            block_done <= 1'b0;
            case (state)
                LOAD: begin
                    scan_valid <= 1'b0;
                    read_pending <= 1'b0;
                    if (store_block_valid) begin
                        group_nonzero <= store_block_group_flags;
                        any_nonzero <= store_block_any_nonzero;
                        last_nonzero_scan_position <=
                            store_block_last_position;
                        input_error <= store_block_input_error;
                        if (store_block_any_nonzero) begin
                            state <= START_SYNTAX;
                        end else begin
                            state <= RELEASE;
                        end
                    end
                end
                START_SYNTAX: begin
                    arbiter_finished <= 1'b0;
                    if (last_s_valid) begin
                        state <= WAIT_LAST;
                    end
                end
                WAIT_LAST: begin
                    if (last_final_fire) begin
                        state <= SIGNIFICANCE_INIT;
                    end
                end
                SIGNIFICANCE_INIT: begin
                    issue_position <= last_nonzero_scan_position;
                    issue_complete <= 1'b0;
                    read_pending <= 1'b0;
                    scan_valid <= 1'b0;
                    state <= SIGNIFICANCE_READ;
                end
                SIGNIFICANCE_READ: begin
                    if (significance_input_error) begin
                        input_error <= 1'b1;
                    end
                    if (reader_advance) begin
                        scan_valid <= read_pending;
                        if (read_pending) begin
                            scan_coefficient <= ram_read_data;
                            scan_nonzero <= (ram_read_data != 0);
                            scan_raster_address <= pending_raster_address;
                            scan_position <= pending_scan_position;
                        end
                        if (!issue_complete) begin
                            pending_raster_address <=
                                scan_to_raster(issue_position);
                            pending_scan_position <= issue_position;
                            read_pending <= 1'b1;
                            if (issue_position == 0) begin
                                issue_complete <= 1'b1;
                            end else begin
                                issue_position <= issue_position - 1'b1;
                            end
                        end else begin
                            read_pending <= 1'b0;
                        end
                    end
                    if (significance_stage_done) begin
                        state <= LEVEL_INIT;
                    end
                end
                LEVEL_INIT: begin
                    issue_position <= last_nonzero_scan_position;
                    issue_complete <= 1'b0;
                    read_pending <= 1'b0;
                    scan_valid <= 1'b0;
                    state <= LEVEL_READ;
                end
                LEVEL_READ: begin
                    if (level_input_error) begin
                        input_error <= 1'b1;
                    end
                    if (reader_advance) begin
                        scan_valid <= read_pending;
                        if (read_pending) begin
                            scan_coefficient <= ram_read_data;
                            scan_nonzero <= (ram_read_data != 0);
                            scan_raster_address <= pending_raster_address;
                            scan_position <= pending_scan_position;
                        end
                        if (!issue_complete) begin
                            pending_raster_address <=
                                scan_to_raster(issue_position);
                            pending_scan_position <= issue_position;
                            read_pending <= 1'b1;
                            if (issue_position == 0) begin
                                issue_complete <= 1'b1;
                            end else begin
                                issue_position <= issue_position - 1'b1;
                            end
                        end else begin
                            read_pending <= 1'b0;
                        end
                    end
                    if (level_block_done) begin
                        state <= WAIT_FINISH;
                    end
                end
                WAIT_FINISH: begin
                    if (arbiter_block_done) begin
                        arbiter_finished <= 1'b1;
                    end
                    if (arbiter_finished && fifo_count == 0) begin
                        state <= RELEASE;
                    end
                end
                RELEASE: begin
                    if (store_release_ready) begin
                        block_done <= 1'b1;
                        arbiter_finished <= 1'b0;
                        state <= LOAD;
                    end
                end
                default: state <= LOAD;
            endcase
        end
    end
endmodule
