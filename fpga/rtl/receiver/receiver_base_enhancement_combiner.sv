module receiver_base_enhancement_combiner #(
    parameter integer WAIT_LIMIT = 4095,
    parameter bit ENABLE_COUNTERS = 1'b1
) (
    input  logic         clk,
    input  logic         rst_n,

    input  logic         stripe_start,
    input  logic         stripe_enhancement_available,

    input  logic         base_valid,
    output logic         base_ready,
    input  logic [6:0]   base_ctu_index,
    input  logic [2:0]   base_block_index,
    input  logic [1:0]   base_plane,
    input  logic [1:0]   base_mode,
    input  logic [7:0]   base_quality,
    input  logic [15:0]  base_frame_id,
    input  logic [7:0]   base_stripe_id,
    input  logic [71:0]  base_coefficients,

    input  logic         enhancement_event_valid,
    output logic         enhancement_event_ready,
    input  logic [1:0]   enhancement_event_kind,
    input  logic [6:0]   enhancement_event_ctu_index,
    input  logic [2:0]   enhancement_event_block_index,
    input  logic [1:0]   enhancement_event_plane,
    input  logic [5:0]   enhancement_event_scan_index,
    input  logic signed [11:0] enhancement_event_coefficient,
    input  logic [7:0]   enhancement_event_quality,
    input  logic [15:0]  enhancement_event_frame_id,
    input  logic [7:0]   enhancement_event_stripe_id,

    output logic         command_valid,
    input  logic         command_ready,
    output wire  [6:0]   command_ctu_index,
    output wire  [2:0]   command_block_index,
    output wire  [1:0]   command_plane,
    output wire  [1:0]   command_mode,
    output wire  [7:0]   command_quality,
    output wire  [15:0]  command_frame_id,
    output wire  [7:0]   command_stripe_id,
    output wire  [767:0] command_coefficients,
    output wire          command_enhanced,

    output logic [31:0]  enhanced_block_count,
    output logic [31:0]  fallback_block_count,
    output logic [31:0]  late_stripe_count,
    output logic         alignment_error
);
    localparam logic [1:0] EVENT_START       = 2'd0;
    localparam logic [1:0] EVENT_COEFFICIENT = 2'd1;
    localparam logic [1:0] EVENT_END         = 2'd2;
    localparam logic [11:0] WAIT_LIMIT_VALUE = 12'(WAIT_LIMIT);

    logic stripe_enhancement_expected;
    logic base_pending;
    logic [6:0] pending_ctu_index;
    logic [2:0] pending_block_index;
    logic [1:0] pending_plane, pending_mode;
    logic [7:0] pending_quality;
    logic [15:0] pending_frame_id;
    logic [7:0] pending_stripe_id;
    logic [71:0] pending_base_coefficients;

    logic enhancement_assembling;
    (* syn_useenables = 0 *) logic enhancement_pending;
    logic [6:0] enhancement_ctu_index;
    logic [2:0] enhancement_block_index;
    logic [1:0] enhancement_plane;
    logic [7:0] enhancement_quality;
    logic [15:0] enhancement_frame_id;
    logic [7:0] enhancement_stripe_id;
    logic signed [11:0] enhancement_coefficients [0:63];
    // Sparse enhancement events only write non-zero coefficients.  A valid
    // bitmap makes stale, uninitialised data invisible without clearing the
    // complete 768-bit coefficient bank at every block boundary.
    logic [63:0] enhancement_coefficient_valid;
    logic [11:0] wait_counter;

    logic event_buffer_valid, event_buffer_ready;
    logic command_load_pending;
    logic command_uses_enhancement;
    logic enhancement_timeout_armed;
    logic [1:0] event_buffer_kind;
    logic [6:0] event_buffer_ctu_index;
    logic [2:0] event_buffer_block_index;
    logic [1:0] event_buffer_plane;
    logic [5:0] event_buffer_scan_index;
    logic signed [11:0] event_buffer_coefficient;
    logic coefficient_write_pending;
    logic [5:0] coefficient_write_address;
    logic signed [11:0] coefficient_write_data;
    logic [7:0] coefficient_bank_write_enable;
    logic [2:0] coefficient_bank_write_index;
    logic signed [11:0] coefficient_bank_write_data;
    logic [7:0] event_buffer_quality;
    logic [15:0] event_buffer_frame_id;
    logic [7:0] event_buffer_stripe_id;

    wire event_fire = event_buffer_valid && event_buffer_ready;
    wire base_fire = base_valid && base_ready;
    wire command_fire = command_valid && command_ready;
    wire enhancement_matches = enhancement_pending
        && (enhancement_ctu_index == pending_ctu_index)
        && (enhancement_block_index == pending_block_index)
        && (enhancement_plane == pending_plane)
        && (enhancement_quality == pending_quality)
        && (enhancement_frame_id == pending_frame_id)
        && (enhancement_stripe_id == pending_stripe_id);
    wire use_enhancement = stripe_enhancement_expected
                         && enhancement_matches;
    wire command_request = base_pending
        && (!stripe_enhancement_expected || enhancement_matches);
    wire command_can_load = command_load_pending
                         && (!command_valid || command_ready);

    assign base_ready = !base_pending;


    always_comb begin
        if (!stripe_enhancement_expected)
            event_buffer_ready = 1'b1;
        else begin
            case (event_buffer_kind)
                EVENT_START:
                    event_buffer_ready = !enhancement_assembling
                                      && !enhancement_pending;
                EVENT_COEFFICIENT:
                    event_buffer_ready = enhancement_assembling;
                EVENT_END:
                    event_buffer_ready = enhancement_assembling;
                default: event_buffer_ready = 1'b1;
            endcase
        end
        enhancement_event_ready = !event_buffer_valid || event_buffer_ready;
    end

    function automatic logic [5:0] zigzag_address(input logic [5:0] index);
        begin
            case (index)
                0:zigzag_address=0;1:zigzag_address=1;2:zigzag_address=8;3:zigzag_address=16;
                4:zigzag_address=9;5:zigzag_address=2;6:zigzag_address=3;7:zigzag_address=10;
                8:zigzag_address=17;9:zigzag_address=24;10:zigzag_address=32;11:zigzag_address=25;
                12:zigzag_address=18;13:zigzag_address=11;14:zigzag_address=4;15:zigzag_address=5;
                16:zigzag_address=12;17:zigzag_address=19;18:zigzag_address=26;19:zigzag_address=33;
                20:zigzag_address=40;21:zigzag_address=48;22:zigzag_address=41;23:zigzag_address=34;
                24:zigzag_address=27;25:zigzag_address=20;26:zigzag_address=13;27:zigzag_address=6;
                28:zigzag_address=7;29:zigzag_address=14;30:zigzag_address=21;31:zigzag_address=28;
                32:zigzag_address=35;33:zigzag_address=42;34:zigzag_address=49;35:zigzag_address=56;
                36:zigzag_address=57;37:zigzag_address=50;38:zigzag_address=43;39:zigzag_address=36;
                40:zigzag_address=29;41:zigzag_address=22;42:zigzag_address=15;43:zigzag_address=23;
                44:zigzag_address=30;45:zigzag_address=37;46:zigzag_address=44;47:zigzag_address=51;
                48:zigzag_address=58;49:zigzag_address=59;50:zigzag_address=52;51:zigzag_address=45;
                52:zigzag_address=38;53:zigzag_address=31;54:zigzag_address=39;55:zigzag_address=46;
                56:zigzag_address=53;57:zigzag_address=60;58:zigzag_address=61;59:zigzag_address=54;
                60:zigzag_address=47;61:zigzag_address=55;62:zigzag_address=62;
                default:zigzag_address=63;
            endcase
        end
    endfunction

    integer combine_index;
    logic [767:0] assembled_coefficients;
    assign command_coefficients = assembled_coefficients;
    assign command_ctu_index = pending_ctu_index;
    assign command_block_index = pending_block_index;
    assign command_plane = pending_plane;
    assign command_mode = pending_mode;
    assign command_quality = pending_quality;
    assign command_frame_id = pending_frame_id;
    assign command_stripe_id = pending_stripe_id;
    assign command_enhanced = command_uses_enhancement;
    always_comb begin
        assembled_coefficients = 768'd0;
        for (combine_index = 0; combine_index < 64;
             combine_index = combine_index + 1)
            if (enhancement_coefficient_valid[combine_index])
                assembled_coefficients[combine_index * 12 +: 12] =
                    enhancement_coefficients[combine_index];
        for (combine_index = 0; combine_index < 6;
             combine_index = combine_index + 1)
            if ((pending_plane == 0) || (combine_index < 3))
                assembled_coefficients[
                    zigzag_address(6'(combine_index)) * 12 +: 12
                ] = pending_base_coefficients[combine_index * 12 +: 12];
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            stripe_enhancement_expected <= 1'b0;
            base_pending <= 1'b0;
            pending_ctu_index <= 7'd0;
            pending_block_index <= 3'd0;
            pending_plane <= 2'd0;
            pending_mode <= 2'd0;
            pending_quality <= 8'd0;
            pending_frame_id <= 16'd0;
            pending_stripe_id <= 8'd0;
            pending_base_coefficients <= 72'd0;
            enhancement_assembling <= 1'b0;
            enhancement_pending <= 1'b0;
            enhancement_ctu_index <= 7'd0;
            enhancement_block_index <= 3'd0;
            enhancement_plane <= 2'd0;
            enhancement_quality <= 8'd0;
            enhancement_frame_id <= 16'd0;
            enhancement_stripe_id <= 8'd0;
            wait_counter <= 12'd0;
            enhancement_timeout_armed <= 1'b0;
            if (ENABLE_COUNTERS) begin
                enhanced_block_count <= 32'd0;
                fallback_block_count <= 32'd0;
                late_stripe_count <= 32'd0;
                alignment_error <= 1'b0;
            end
            enhancement_coefficient_valid <= 64'd0;
            event_buffer_valid <= 1'b0;
            event_buffer_scan_index <= 6'd0;
            coefficient_write_pending <= 1'b0;
            coefficient_write_address <= 6'd0;
            coefficient_write_data <= 12'sd0;
            coefficient_bank_write_enable <= 8'd0;
            coefficient_bank_write_index <= 3'd0;
            coefficient_bank_write_data <= 12'sd0;
            command_valid <= 1'b0;
            command_load_pending <= 1'b0;
            command_uses_enhancement <= 1'b0;
        end else begin
            coefficient_write_pending <= 1'b0;
            coefficient_bank_write_enable <= 8'd0;
            // Do not queue the currently presented command again while it
            // is waiting for, or firing into, the transform.  base_pending
            // is cleared on the same edge as command_fire, so looking only
            // at command_request here would re-arm command_load_pending from
            // its pre-edge value and emit every accepted block twice.
            if (!command_load_pending && !command_valid && command_request)
                command_load_pending <= 1'b1;
            if (enhancement_event_ready) begin
                event_buffer_valid <= enhancement_event_valid;
                if (enhancement_event_valid) begin
                    event_buffer_kind <= enhancement_event_kind;
                    event_buffer_ctu_index <= enhancement_event_ctu_index;
                    event_buffer_block_index <=
                        enhancement_event_block_index;
                    event_buffer_plane <= enhancement_event_plane;
                    // Register the compact index first; expanding it here
                    // created a 64-bit remote path and consumed 64 FFs.
                    event_buffer_scan_index <= enhancement_event_scan_index;
                    event_buffer_coefficient <=
                        enhancement_event_coefficient;
                    event_buffer_quality <= enhancement_event_quality;
                    event_buffer_frame_id <= enhancement_event_frame_id;
                    event_buffer_stripe_id <= enhancement_event_stripe_id;
                end
            end
            if (stripe_start) begin
                stripe_enhancement_expected <=
                    stripe_enhancement_available;
                enhancement_assembling <= 1'b0;
                enhancement_pending <= 1'b0;
                enhancement_coefficient_valid <= 64'd0;
                wait_counter <= 12'd0;
                enhancement_timeout_armed <= 1'b0;
            end

            if (base_fire) begin
                base_pending <= 1'b1;
                pending_ctu_index <= base_ctu_index;
                pending_block_index <= base_block_index;
                pending_plane <= base_plane;
                pending_mode <= base_mode;
                pending_quality <= base_quality;
                pending_frame_id <= base_frame_id;
                pending_stripe_id <= base_stripe_id;
                pending_base_coefficients <= base_coefficients;
                wait_counter <= 12'd0;
                enhancement_timeout_armed <= 1'b0;
            end else if (base_pending && stripe_enhancement_expected
                         && !command_load_pending) begin
                if (enhancement_timeout_armed) begin
                    stripe_enhancement_expected <= 1'b0;
                    enhancement_assembling <= 1'b0;
                    enhancement_pending <= 1'b0;
                    if (ENABLE_COUNTERS)
                        late_stripe_count <= late_stripe_count + 1'b1;
                    enhancement_coefficient_valid <= 64'd0;
                    enhancement_timeout_armed <= 1'b0;
                end else if (wait_counter == WAIT_LIMIT_VALUE) begin
                    enhancement_timeout_armed <= 1'b1;
                end else begin
                    wait_counter <= wait_counter + 1'b1;
                end
            end

            if (event_buffer_valid && enhancement_assembling
                && (event_buffer_kind == EVENT_COEFFICIENT)) begin
                coefficient_write_pending <= 1'b1;
                coefficient_write_address <=
                    zigzag_address(event_buffer_scan_index);
                coefficient_write_data <= event_buffer_coefficient;
            end
            if (coefficient_write_pending && !stripe_start) begin
                coefficient_bank_write_enable <=
                    8'b1 << coefficient_write_address[5:3];
                coefficient_bank_write_index <= coefficient_write_address[2:0];
                coefficient_bank_write_data <= coefficient_write_data;
            end
            for (combine_index = 0; combine_index < 8;
                 combine_index = combine_index + 1) begin
                if (coefficient_bank_write_enable[combine_index]
                    && !stripe_start) begin
                    enhancement_coefficients[
                        combine_index * 8 + coefficient_bank_write_index
                    ] <= coefficient_bank_write_data;
                    enhancement_coefficient_valid[
                        combine_index * 8 + coefficient_bank_write_index
                    ] <= 1'b1;
                end
            end

            if (event_fire) begin
                case (event_buffer_kind)
                    EVENT_START: begin
                        enhancement_assembling <=
                            stripe_enhancement_expected;
                        enhancement_ctu_index <=
                            event_buffer_ctu_index;
                        enhancement_block_index <=
                            event_buffer_block_index;
                        enhancement_plane <= event_buffer_plane;
                        enhancement_quality <= event_buffer_quality;
                        enhancement_frame_id <= event_buffer_frame_id;
                        enhancement_stripe_id <= event_buffer_stripe_id;
                        enhancement_coefficient_valid <= 64'd0;
                    end
                    EVENT_COEFFICIENT: begin end
                    EVENT_END: begin
                        if (enhancement_assembling) begin
                            enhancement_assembling <= 1'b0;
                            enhancement_pending <= 1'b1;
                        end
                    end
                    default: if (ENABLE_COUNTERS)
                        alignment_error <= 1'b1;
                endcase
            end

            if (ENABLE_COUNTERS && enhancement_pending && base_pending
                && !enhancement_matches)
                alignment_error <= 1'b1;

            if (command_fire) begin
                command_valid <= 1'b0;
                base_pending <= 1'b0;
                wait_counter <= 12'd0;
                enhancement_timeout_armed <= 1'b0;
                if (command_uses_enhancement) begin
                    enhancement_pending <= 1'b0;
                    if (ENABLE_COUNTERS)
                        enhanced_block_count <= enhanced_block_count + 1'b1;
                end else begin
                    if (ENABLE_COUNTERS)
                        fallback_block_count <= fallback_block_count + 1'b1;
                end
            end

            if (command_can_load) begin
                command_load_pending <= 1'b0;
                command_uses_enhancement <= use_enhancement;
                command_valid <= 1'b1;
            end
        end
    end
endmodule
