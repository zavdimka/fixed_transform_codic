module hevc_coefficient_syntax8 (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               s_valid,
    output logic               s_ready,
    input  logic [5:0]         s_raster_address,
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
    output logic [5:0]         m_scan_position,
    output logic [1:0]         m_group_scan_position,
    output logic [3:0]         m_coefficient_index,

    output logic               block_done,
    output logic               any_nonzero,
    output logic [5:0]         last_nonzero_scan_position,
    output logic [3:0]         significant_group_flags,
    output logic               busy,
    output logic               input_error
);
    typedef enum logic [3:0] {
        LOAD, START_SYNTAX, WAIT_LAST,
        SIGNIFICANCE_INIT, SIGNIFICANCE_READ,
        LEVEL_INIT, LEVEL_READ, WAIT_FINISH, ZERO_DONE
    } state_t;
    state_t state;

    logic signed [15:0] coefficient_memory [0:63];
    logic [5:0] load_count;
    logic [3:0] group_nonzero;
    logic [5:0] issue_position;
    logic issue_complete;
    logic read_pending;
    logic signed [15:0] ram_read_data;
    logic [5:0] pending_raster_address;
    logic [5:0] pending_scan_position;
    logic scan_valid;
    logic signed [15:0] scan_coefficient;
    logic [5:0] scan_raster_address;
    logic [5:0] scan_position;

    logic last_s_ready, last_m_valid, last_m_ready;
    logic last_m_bin, last_m_bypass, last_m_axis_y;
    logic [2:0] last_m_context_index;
    logic last_m_syntax_last;

    logic significance_s_ready, significance_m_valid;
    logic significance_m_ready, significance_m_bin;
    logic significance_m_coded_sub_block;
    logic [3:0] significance_m_context_index;
    logic [5:0] significance_m_scan_position;
    logic significance_stage_done, significance_input_error;

    logic level_s_ready, level_m_valid, level_m_ready;
    logic level_m_bin, level_m_bypass;
    logic [1:0] level_m_kind;
    logic [4:0] level_m_context_index;
    logic [3:0] level_m_group_scan_position;
    logic [3:0] level_m_coefficient_index;
    logic level_block_done, level_input_error;

    logic arbiter_start_ready, arbiter_block_done;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [7:0] arbiter_m_scan_position;
    logic [3:0] arbiter_m_group_scan_position;
    /* verilator lint_on UNUSEDSIGNAL */
    logic unused_last_busy, unused_significance_syntax_last;
    logic unused_significance_busy, unused_level_group_done;
    logic unused_level_busy, unused_arbiter_busy;

    function automatic logic [3:0] diagonal4(input logic [3:0] index);
        case (index)
            0:diagonal4=0; 1:diagonal4=4; 2:diagonal4=1; 3:diagonal4=8;
            4:diagonal4=5; 5:diagonal4=2; 6:diagonal4=12; 7:diagonal4=9;
            8:diagonal4=6; 9:diagonal4=3; 10:diagonal4=13; 11:diagonal4=10;
            12:diagonal4=7; 13:diagonal4=14; 14:diagonal4=11;
            default:diagonal4=15;
        endcase
    endfunction
    function automatic logic [3:0] inverse4(input logic [3:0] raster);
        case (raster)
            0:inverse4=0; 1:inverse4=2; 2:inverse4=5; 3:inverse4=9;
            4:inverse4=1; 5:inverse4=4; 6:inverse4=8; 7:inverse4=12;
            8:inverse4=3; 9:inverse4=7; 10:inverse4=11; 11:inverse4=14;
            12:inverse4=6; 13:inverse4=10; 14:inverse4=13;
            default:inverse4=15;
        endcase
    endfunction
    function automatic logic [1:0] diagonal2(input logic [1:0] index);
        case (index) 0:diagonal2=0; 1:diagonal2=2;
            2:diagonal2=1; default:diagonal2=3; endcase
    endfunction
    function automatic logic [1:0] inverse2(input logic [1:0] raster);
        case (raster) 0:inverse2=0; 1:inverse2=2;
            2:inverse2=1; default:inverse2=3; endcase
    endfunction
    function automatic logic [5:0] scan_to_raster(input logic [5:0] position);
        logic [1:0] group_raster;
        logic [3:0] local_raster;
        begin
            group_raster = diagonal2(position[5:4]);
            local_raster = diagonal4(position[3:0]);
            scan_to_raster = {group_raster[1], local_raster[3:2],
                              group_raster[0], local_raster[1:0]};
        end
    endfunction

    wire [1:0] write_group_raster = {s_raster_address[5], s_raster_address[2]};
    wire [3:0] write_local_raster = {s_raster_address[4:3], s_raster_address[1:0]};
    wire [5:0] write_scan_position = {
        inverse2(write_group_raster), inverse4(write_local_raster)
    };
    wire write_nonzero = s_coefficient != 0;
    wire reader_active = state == SIGNIFICANCE_READ || state == LEVEL_READ;
    wire reader_ready = state == SIGNIFICANCE_READ ?
                        significance_s_ready : level_s_ready;
    wire reader_advance = !scan_valid || reader_ready;
    wire ram_read_enable = reader_active && reader_advance && !issue_complete;
    wire [5:0] ram_read_address = scan_to_raster(issue_position);
    wire scan_group_nonzero = group_nonzero[diagonal2(scan_position[5:4])];
    wire last_start_valid = state == START_SYNTAX &&
                            last_s_ready && arbiter_start_ready;
    wire last_final_fire = last_m_valid && last_m_ready && last_m_syntax_last;

    assign s_ready = state == LOAD;
    assign busy = state != LOAD;
    assign significant_group_flags = group_nonzero;

    hevc_last_sig_bins8 last_significant (
        .clk(clk), .rst_n(rst_n), .s_valid(last_start_valid),
        .s_ready(last_s_ready),
        .s_raster_address(scan_to_raster(last_nonzero_scan_position)),
        .m_valid(last_m_valid), .m_ready(last_m_ready),
        .m_bin(last_m_bin), .m_bypass(last_m_bypass),
        .m_axis_y(last_m_axis_y), .m_context_index(last_m_context_index),
        .m_syntax_last(last_m_syntax_last), .busy(unused_last_busy)
    );

    hevc_significance_bins8 significance (
        .clk(clk), .rst_n(rst_n),
        .s_valid(state == SIGNIFICANCE_READ && scan_valid),
        .s_ready(significance_s_ready), .s_raster_address(scan_raster_address),
        .s_scan_position(scan_position), .s_coefficient(scan_coefficient),
        .s_group_nonzero(scan_group_nonzero),
        .s_significant_group_flags(group_nonzero),
        .s_block_last(scan_position == 0),
        .m_valid(significance_m_valid), .m_ready(significance_m_ready),
        .m_bin(significance_m_bin),
        .m_coded_sub_block(significance_m_coded_sub_block),
        .m_context_index(significance_m_context_index),
        .m_scan_position(significance_m_scan_position),
        .m_syntax_last(unused_significance_syntax_last),
        .stage_done(significance_stage_done),
        .busy(unused_significance_busy), .input_error(significance_input_error)
    );

    hevc_coefficient_level_bins16 #(.CHROMA(1'b1)) levels (
        .clk(clk), .rst_n(rst_n),
        .s_valid(state == LEVEL_READ && scan_valid), .s_ready(level_s_ready),
        .s_coefficient(scan_coefficient),
        .s_group_scan_position({2'd0, scan_position[5:4]}),
        .s_block_start(state == LEVEL_READ &&
                       scan_position == last_nonzero_scan_position),
        .s_group_end(state == LEVEL_READ && scan_position[3:0] == 0),
        .s_block_last(state == LEVEL_READ && scan_position == 0),
        .m_valid(level_m_valid), .m_ready(level_m_ready),
        .m_bin(level_m_bin), .m_bypass(level_m_bypass), .m_kind(level_m_kind),
        .m_context_index(level_m_context_index),
        .m_group_scan_position(level_m_group_scan_position),
        .m_coefficient_index(level_m_coefficient_index),
        .group_done(unused_level_group_done), .block_done(level_block_done),
        .busy(unused_level_busy), .input_error(level_input_error)
    );

    hevc_coefficient_syntax_arbiter16 arbiter (
        .clk(clk), .rst_n(rst_n),
        .s_start_valid(last_start_valid), .s_start_ready(arbiter_start_ready),
        .s_last_valid(last_m_valid), .s_last_ready(last_m_ready),
        .s_last_bin(last_m_bin), .s_last_bypass(last_m_bypass),
        .s_last_axis_y(last_m_axis_y),
        .s_last_context_index({1'b0, last_m_context_index}),
        .s_last_syntax_last(last_m_syntax_last),
        .s_significance_valid(significance_m_valid),
        .s_significance_ready(significance_m_ready),
        .s_significance_bin(significance_m_bin),
        .s_significance_coded_sub_block(significance_m_coded_sub_block),
        .s_significance_context_index({1'b0, significance_m_context_index}),
        .s_significance_scan_position({2'd0, significance_m_scan_position}),
        .s_significance_done(significance_stage_done),
        .s_level_valid(level_m_valid), .s_level_ready(level_m_ready),
        .s_level_bin(level_m_bin), .s_level_bypass(level_m_bypass),
        .s_level_kind(level_m_kind),
        .s_level_context_index(level_m_context_index),
        .s_level_group_scan_position(level_m_group_scan_position),
        .s_level_coefficient_index(level_m_coefficient_index),
        .s_level_done(level_block_done),
        .m_valid(m_valid), .m_ready(m_ready), .m_bin(m_bin),
        .m_bypass(m_bypass), .m_source(m_source),
        .m_level_kind(m_level_kind), .m_context_index(m_context_index),
        .m_last_axis_y(m_last_axis_y),
        .m_significance_coded_sub_block(m_significance_coded_sub_block),
        .m_scan_position(arbiter_m_scan_position),
        .m_group_scan_position(arbiter_m_group_scan_position),
        .m_coefficient_index(m_coefficient_index),
        .block_done(arbiter_block_done), .busy(unused_arbiter_busy)
    );

    assign m_scan_position = arbiter_m_scan_position[5:0];
    assign m_group_scan_position = arbiter_m_group_scan_position[1:0];

    always_ff @(posedge clk) begin
        if (ram_read_enable) begin
            ram_read_data <= coefficient_memory[ram_read_address];
        end
        if (s_valid && s_ready) begin
            coefficient_memory[s_raster_address] <= s_coefficient;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= LOAD;
            load_count <= 0;
            group_nonzero <= 0;
            any_nonzero <= 0;
            last_nonzero_scan_position <= 0;
            issue_position <= 0;
            issue_complete <= 0;
            read_pending <= 0;
            pending_raster_address <= 0;
            pending_scan_position <= 0;
            scan_valid <= 0;
            scan_coefficient <= 0;
            scan_raster_address <= 0;
            scan_position <= 0;
            block_done <= 0;
            input_error <= 0;
        end else begin
            block_done <= 0;
            case (state)
                LOAD: if (s_valid) begin
                    if (load_count == 0) begin
                        group_nonzero <= write_nonzero ?
                            (4'b0001 << write_group_raster) : 0;
                        any_nonzero <= write_nonzero;
                        last_nonzero_scan_position <= write_nonzero ?
                            write_scan_position : 0;
                        input_error <= 0;
                    end else if (write_nonzero) begin
                        group_nonzero[write_group_raster] <= 1'b1;
                        any_nonzero <= 1'b1;
                        if (!any_nonzero || write_scan_position >
                                last_nonzero_scan_position)
                            last_nonzero_scan_position <= write_scan_position;
                    end
                    if (s_block_last || load_count == 63) begin
                        input_error <= s_block_last != (load_count == 63);
                        load_count <= 0;
                        if (write_nonzero && (!any_nonzero ||
                                write_scan_position > last_nonzero_scan_position))
                            last_nonzero_scan_position <= write_scan_position;
                        if (write_nonzero || any_nonzero)
                            state <= START_SYNTAX;
                        else state <= ZERO_DONE;
                    end else load_count <= load_count + 1'b1;
                end
                START_SYNTAX: if (last_start_valid) state <= WAIT_LAST;
                WAIT_LAST: if (last_final_fire) state <= SIGNIFICANCE_INIT;
                SIGNIFICANCE_INIT: begin
                    issue_position <= last_nonzero_scan_position;
                    issue_complete <= 0; read_pending <= 0; scan_valid <= 0;
                    state <= SIGNIFICANCE_READ;
                end
                SIGNIFICANCE_READ: begin
                    if (significance_input_error) input_error <= 1;
                    if (reader_advance) begin
                        scan_valid <= read_pending;
                        if (read_pending) begin
                            scan_coefficient <= ram_read_data;
                            scan_raster_address <= pending_raster_address;
                            scan_position <= pending_scan_position;
                        end
                        if (!issue_complete) begin
                            pending_raster_address <= ram_read_address;
                            pending_scan_position <= issue_position;
                            read_pending <= 1;
                            if (issue_position == 0) issue_complete <= 1;
                            else issue_position <= issue_position - 1'b1;
                        end else read_pending <= 0;
                    end
                    if (significance_stage_done) state <= LEVEL_INIT;
                end
                LEVEL_INIT: begin
                    issue_position <= last_nonzero_scan_position;
                    issue_complete <= 0; read_pending <= 0; scan_valid <= 0;
                    state <= LEVEL_READ;
                end
                LEVEL_READ: begin
                    if (level_input_error) input_error <= 1;
                    if (reader_advance) begin
                        scan_valid <= read_pending;
                        if (read_pending) begin
                            scan_coefficient <= ram_read_data;
                            scan_raster_address <= pending_raster_address;
                            scan_position <= pending_scan_position;
                        end
                        if (!issue_complete) begin
                            pending_raster_address <= ram_read_address;
                            pending_scan_position <= issue_position;
                            read_pending <= 1;
                            if (issue_position == 0) issue_complete <= 1;
                            else issue_position <= issue_position - 1'b1;
                        end else read_pending <= 0;
                    end
                    if (level_block_done) state <= WAIT_FINISH;
                end
                WAIT_FINISH: if (arbiter_block_done) begin
                    block_done <= 1; state <= LOAD;
                end
                ZERO_DONE: begin block_done <= 1; state <= LOAD; end
                default: state <= LOAD;
            endcase
        end
    end
endmodule
