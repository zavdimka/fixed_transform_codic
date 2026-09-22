module receiver_base_enhancement_stream_join #(
    parameter integer WAIT_LIMIT = 4095,
    parameter bit ENABLE_COUNTERS = 1'b1
) (
    input  logic clk,
    input  logic rst_n,
    input  logic stripe_start,
    input  logic stripe_enhancement_available,

    input  logic base_valid,
    output logic base_ready,
    input  logic [6:0] base_ctu_index,
    input  logic [2:0] base_block_index,
    input  logic [1:0] base_plane,
    input  logic [1:0] base_mode,
    input  logic [7:0] base_quality,
    input  logic [15:0] base_frame_id,
    input  logic [7:0] base_stripe_id,
    input  logic [71:0] base_coefficients,

    input  logic enhancement_event_valid,
    output logic enhancement_event_ready,
    input  logic [1:0] enhancement_event_kind,
    input  logic [6:0] enhancement_event_ctu_index,
    input  logic [2:0] enhancement_event_block_index,
    input  logic [1:0] enhancement_event_plane,
    input  logic [5:0] enhancement_event_scan_index,
    input  logic signed [11:0] enhancement_event_coefficient,
    input  logic [7:0] enhancement_event_quality,
    input  logic [15:0] enhancement_event_frame_id,
    input  logic [7:0] enhancement_event_stripe_id,

    output logic load_start_valid,
    input  logic load_start_ready,
    output logic [6:0] load_ctu_index,
    output logic [2:0] load_block_index,
    output logic [1:0] load_plane,
    output logic [1:0] load_mode,
    output logic [7:0] load_quality,
    output logic [15:0] load_frame_id,
    output logic [7:0] load_stripe_id,
    output logic load_coeff_valid,
    input  logic load_coeff_ready,
    output logic [5:0] load_coeff_address,
    output logic signed [11:0] load_coeff_data,
    output logic load_base_valid,
    input  logic load_base_ready,
    output logic [71:0] load_base_coefficients,
    output logic load_base_plane,
    output logic load_commit_valid,
    input  logic load_commit_ready,
    output logic load_abort,

    output logic [31:0] enhanced_block_count,
    output logic [31:0] fallback_block_count,
    output logic [31:0] late_stripe_count,
    output logic alignment_error
);
    localparam logic [1:0] EVENT_START = 2'd0;
    localparam logic [1:0] EVENT_COEFFICIENT = 2'd1;
    localparam logic [1:0] EVENT_END = 2'd2;
    localparam logic [11:0] WAIT_LIMIT_VALUE = 12'(WAIT_LIMIT);

    typedef enum logic [2:0] {
        IDLE, ENHANCEMENT, WAIT_BASE, BASE_START,
        BASE_WRITE, COMMIT, ABORT_LOAD
    } state_t;
    state_t state;

    logic enhancement_expected, drop_enhancement;
    logic base_pending, load_started, block_enhanced;
    logic [6:0] pending_ctu_index, enhancement_ctu_index;
    logic [2:0] pending_block_index, enhancement_block_index;
    logic [1:0] pending_plane, pending_mode, enhancement_plane;
    logic [7:0] pending_quality, enhancement_quality;
    logic [15:0] pending_frame_id, enhancement_frame_id;
    logic [7:0] pending_stripe_id, enhancement_stripe_id;
    logic [71:0] pending_base_coefficients;
    logic [2:0] base_write_index;
    logic [11:0] wait_counter;

    wire base_fire = base_valid && base_ready;
    wire event_fire = enhancement_event_valid && enhancement_event_ready;
    wire start_fire = load_start_valid && load_start_ready;
    wire coefficient_fire = load_coeff_valid && load_coeff_ready;
    wire base_load_fire = load_base_valid && load_base_ready;
    wire commit_fire = load_commit_valid && load_commit_ready;
    wire pending_matches_enhancement =
           (pending_ctu_index == enhancement_ctu_index)
        && (pending_block_index == enhancement_block_index)
        && (pending_plane == enhancement_plane)
        && (pending_quality == enhancement_quality)
        && (pending_frame_id == enhancement_frame_id)
        && (pending_stripe_id == enhancement_stripe_id);
    wire [2:0] base_last_index = (pending_plane == 0) ? 3'd5 : 3'd2;

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

    always_comb begin
        base_ready = !base_pending;
        enhancement_event_ready = 1'b0;
        load_start_valid = 1'b0;
        load_ctu_index = pending_ctu_index;
        load_block_index = pending_block_index;
        load_plane = pending_plane;
        load_mode = pending_mode;
        load_quality = pending_quality;
        load_frame_id = pending_frame_id;
        load_stripe_id = pending_stripe_id;
        load_coeff_valid = 1'b0;
        load_coeff_address = 6'd0;
        load_coeff_data = 12'sd0;
        load_base_valid = 1'b0;
        load_base_coefficients = pending_base_coefficients;
        load_base_plane = (pending_plane != 0);
        load_commit_valid = 1'b0;
        load_abort = stripe_start || (state == ABORT_LOAD);

        if (drop_enhancement)
            enhancement_event_ready = 1'b1;

        case (state)
            IDLE: begin
                if (enhancement_expected && enhancement_event_valid
                    && (enhancement_event_kind == EVENT_START)) begin
                    load_start_valid = 1'b1;
                    load_ctu_index = enhancement_event_ctu_index;
                    load_block_index = enhancement_event_block_index;
                    load_plane = enhancement_event_plane;
                    load_mode = base_pending ? pending_mode : 2'd0;
                    load_quality = enhancement_event_quality;
                    enhancement_event_ready = load_start_ready;
                end else if (enhancement_expected
                             && enhancement_event_valid) begin
                    // Drain malformed events without creating a global stall.
                    enhancement_event_ready = 1'b1;
                end
            end
            ENHANCEMENT: begin
                if (enhancement_event_kind == EVENT_COEFFICIENT) begin
                    load_coeff_valid = enhancement_event_valid;
                    load_coeff_address = zigzag_address(
                        enhancement_event_scan_index
                    );
                    load_coeff_data = enhancement_event_coefficient;
                    enhancement_event_ready = load_coeff_ready;
                end else begin
                    enhancement_event_ready = 1'b1;
                end
            end
            BASE_START: load_start_valid = 1'b1;
            BASE_WRITE: load_base_valid = 1'b1;
            COMMIT: load_commit_valid = 1'b1;
            default: begin end
        endcase
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            enhancement_expected <= 1'b0;
            drop_enhancement <= 1'b0;
            base_pending <= 1'b0;
            load_started <= 1'b0;
            block_enhanced <= 1'b0;
            base_write_index <= 3'd0;
            wait_counter <= 12'd0;
            alignment_error <= 1'b0;
            enhanced_block_count <= 32'd0;
            fallback_block_count <= 32'd0;
            late_stripe_count <= 32'd0;
        end else begin
            if (stripe_start) begin
                state <= IDLE;
                enhancement_expected <= stripe_enhancement_available;
                drop_enhancement <= 1'b0;
                base_pending <= 1'b0;
                load_started <= 1'b0;
                block_enhanced <= 1'b0;
                wait_counter <= 12'd0;
            end else begin
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
                end

                case (state)
                    IDLE: begin
                        if (start_fire) begin
                            load_started <= 1'b1;
                            enhancement_ctu_index <= enhancement_event_ctu_index;
                            enhancement_block_index <= enhancement_event_block_index;
                            enhancement_plane <= enhancement_event_plane;
                            enhancement_quality <= enhancement_event_quality;
                            enhancement_frame_id <= enhancement_event_frame_id;
                            enhancement_stripe_id <= enhancement_event_stripe_id;
                            state <= ENHANCEMENT;
                        end else if (base_pending && !enhancement_expected) begin
                            state <= BASE_START;
                        end
                    end
                    ENHANCEMENT: begin
                        if (base_pending && !pending_matches_enhancement) begin
                            state <= ABORT_LOAD;
                            load_started <= 1'b0;
                            block_enhanced <= 1'b0;
                            enhancement_expected <= 1'b0;
                            drop_enhancement <= 1'b1;
                            if (ENABLE_COUNTERS)
                                alignment_error <= 1'b1;
                        end else if (event_fire
                            && (enhancement_event_kind == EVENT_END)) begin
                            block_enhanced <= 1'b1;
                            if (base_pending) begin
                                base_write_index <= 3'd0;
                                state <= BASE_WRITE;
                            end else begin
                                state <= WAIT_BASE;
                            end
                        end else if (event_fire
                                     && (enhancement_event_kind == EVENT_START)
                                     && ENABLE_COUNTERS) begin
                            alignment_error <= 1'b1;
                        end
                    end
                    WAIT_BASE: if (base_pending) begin
                        if (!pending_matches_enhancement) begin
                            state <= ABORT_LOAD;
                            load_started <= 1'b0;
                            block_enhanced <= 1'b0;
                            enhancement_expected <= 1'b0;
                            drop_enhancement <= 1'b1;
                            if (ENABLE_COUNTERS)
                                alignment_error <= 1'b1;
                        end else begin
                            base_write_index <= 3'd0;
                            state <= BASE_WRITE;
                        end
                    end
                    BASE_START: if (start_fire) begin
                        load_started <= 1'b1;
                        block_enhanced <= 1'b0;
                        base_write_index <= 3'd0;
                        state <= BASE_WRITE;
                    end
                    BASE_WRITE: if (base_load_fire)
                        state <= COMMIT;
                    COMMIT: if (commit_fire) begin
                        state <= IDLE;
                        base_pending <= 1'b0;
                        load_started <= 1'b0;
                        wait_counter <= 12'd0;
                        if (ENABLE_COUNTERS) begin
                            if (block_enhanced)
                                enhanced_block_count <= enhanced_block_count + 1'b1;
                            else
                                fallback_block_count <= fallback_block_count + 1'b1;
                        end
                        block_enhanced <= 1'b0;
                    end
                    ABORT_LOAD: state <= BASE_START;
                    default: state <= IDLE;
                endcase

                if (base_pending && enhancement_expected
                    && ((state == IDLE) || (state == ENHANCEMENT)
                        || (state == WAIT_BASE))) begin
                    if (wait_counter == WAIT_LIMIT_VALUE) begin
                        enhancement_expected <= 1'b0;
                        drop_enhancement <= 1'b1;
                        block_enhanced <= 1'b0;
                        base_write_index <= 3'd0;
                        state <= load_started ? BASE_WRITE : BASE_START;
                        if (ENABLE_COUNTERS)
                            late_stripe_count <= late_stripe_count + 1'b1;
                    end else begin
                        wait_counter <= wait_counter + 1'b1;
                    end
                end
            end
        end
    end
endmodule
