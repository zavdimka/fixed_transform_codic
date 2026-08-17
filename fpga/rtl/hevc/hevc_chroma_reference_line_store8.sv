/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
module hevc_chroma_reference_line_store8 #(
    parameter integer FRAME_WIDTH = 1280,
    parameter integer CTU_COLUMNS = FRAME_WIDTH / 16
) (
    input  logic       clk,
    input  logic       rst_n,

    input  logic       start_valid,
    output logic       start_ready,
    input  logic [6:0] ctu_x,
    input  logic       top_available,

    output logic       m_valid,
    input  logic       m_ready,
    output logic [7:0] m_ref_top,
    output logic [7:0] m_ref_left,
    output logic       m_ref_last,

    input  logic       recon_valid,
    input  logic [7:0] recon_pixel,
    input  logic [2:0] recon_x,
    input  logic [2:0] recon_y,
    input  logic       recon_block_last,

    output logic       block_committed,
    output logic       protocol_error,
    output logic       parameter_error,
    output logic       busy
);
    localparam integer CHROMA_WIDTH = FRAME_WIDTH / 2;
    localparam integer ADDRESS_WIDTH = (CHROMA_WIDTH <= 2) ? 1 :
        $clog2(CHROMA_WIDTH);

    typedef enum logic [2:0] {
        IDLE,
        SCAN_ISSUE,
        SCAN_CAPTURE,
        PREPARE_OUTPUT,
        OUTPUT_REFERENCES,
        WAIT_RECONSTRUCTION
    } state_t;

    localparam logic [2:0] SOURCE_NONE = 3'd0;
    localparam logic [2:0] SOURCE_TOP = 3'd1;
    localparam logic [2:0] SOURCE_LEFT = 3'd2;
    localparam logic [2:0] SOURCE_CORNER = 3'd3;

    state_t state;
    logic [6:0] latched_ctu_x;
    logic latched_top_available;

    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    logic [7:0] top_line [0:CHROMA_WIDTH-1];
    logic [7:0] left_edge [0:7];
    logic [7:0] carried_top_left;

    logic [4:0] scan_index;
    logic [3:0] output_index;
    logic [7:0] raw_reference [0:18];
    logic raw_available [0:18];
    logic [7:0] filled_reference [0:18];
    logic [7:0] filled_reference_next [0:18];

    logic candidate_available;
    logic [2:0] candidate_source;
    logic [ADDRESS_WIDTH-1:0] candidate_address;
    logic [2:0] candidate_left_index;
    logic pending_available;
    logic [2:0] pending_source;
    logic [2:0] pending_left_index;
    logic [7:0] top_read_data;

    logic [ADDRESS_WIDTH-1:0] block_base;
    logic [ADDRESS_WIDTH-1:0] recon_address;
    integer sample_offset;
    integer fill_index;
    integer capture_index;
    logic [7:0] first_available_sample;
    logic [7:0] running_sample;
    logic found_available;

    wire geometry_valid = (FRAME_WIDTH >= 16) &&
        ((FRAME_WIDTH % 16) == 0) &&
        (CTU_COLUMNS == (FRAME_WIDTH / 16)) &&
        (CTU_COLUMNS > 0) && (CTU_COLUMNS <= 128);
    wire start_fire = start_valid && start_ready;
    wire output_fire = m_valid && m_ready;
    wire recon_fire = recon_valid && (state == WAIT_RECONSTRUCTION);

    assign block_base = latched_ctu_x << 3;
    assign recon_address = block_base + recon_x;
    assign start_ready = (state == IDLE) && geometry_valid;
    assign parameter_error = !geometry_valid;
    assign busy = state != IDLE;
    assign m_valid = state == OUTPUT_REFERENCES;
    assign m_ref_last = output_index == 9;
    assign m_ref_top = (output_index == 0) ?
        filled_reference[9] : filled_reference[9 + output_index];
    assign m_ref_left = (output_index == 0) ?
        filled_reference[9] : filled_reference[9 - output_index];

    always_comb begin
        candidate_available = 1'b0;
        candidate_source = SOURCE_NONE;
        candidate_address = '0;
        candidate_left_index = 3'd0;
        sample_offset = 0;

        if (scan_index < 9) begin
            sample_offset = 8 - scan_index;
            if ((latched_ctu_x != 0) && (sample_offset < 8)) begin
                candidate_available = 1'b1;
                candidate_source = SOURCE_LEFT;
                candidate_left_index = sample_offset[2:0];
            end
        end else if (scan_index == 9) begin
            if (latched_top_available && (latched_ctu_x != 0)) begin
                candidate_available = 1'b1;
                candidate_source = SOURCE_CORNER;
            end
        end else begin
            sample_offset = scan_index - 10;
            if (latched_top_available &&
                ((block_base + sample_offset) < CHROMA_WIDTH)) begin
                candidate_available = 1'b1;
                candidate_source = SOURCE_TOP;
                candidate_address = block_base + sample_offset;
            end
        end
    end

    always_comb begin
        first_available_sample = 8'd128;
        found_available = 1'b0;
        for (fill_index = 0; fill_index < 19; fill_index = fill_index + 1) begin
            if (!found_available && raw_available[fill_index]) begin
                first_available_sample = raw_reference[fill_index];
                found_available = 1'b1;
            end
        end

        running_sample = first_available_sample;
        for (fill_index = 0; fill_index < 19; fill_index = fill_index + 1) begin
            if (raw_available[fill_index])
                running_sample = raw_reference[fill_index];
            filled_reference_next[fill_index] = running_sample;
        end
    end

    always_ff @(posedge clk) begin
        if ((state == SCAN_ISSUE) && candidate_available &&
            (candidate_source == SOURCE_TOP))
            top_read_data <= top_line[candidate_address];
        if (recon_fire && (recon_y == 7))
            top_line[recon_address] <= recon_pixel;
        if (recon_fire && (recon_x == 7))
            left_edge[recon_y] <= recon_pixel;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            latched_ctu_x <= 7'd0;
            latched_top_available <= 1'b0;
            carried_top_left <= 8'd128;
            scan_index <= 5'd0;
            output_index <= 4'd0;
            pending_available <= 1'b0;
            pending_source <= SOURCE_NONE;
            pending_left_index <= 3'd0;
            block_committed <= 1'b0;
            protocol_error <= 1'b0;
        end else begin
            block_committed <= 1'b0;

            if (start_fire) begin
                latched_ctu_x <= ctu_x;
                latched_top_available <= top_available;
                scan_index <= 5'd0;
                output_index <= 4'd0;
                protocol_error <= 1'b0;
                state <= SCAN_ISSUE;
            end

            if (state == SCAN_ISSUE) begin
                pending_available <= candidate_available;
                pending_source <= candidate_source;
                pending_left_index <= candidate_left_index;
                state <= SCAN_CAPTURE;
            end else if (state == SCAN_CAPTURE) begin
                raw_available[scan_index] <= pending_available;
                case (pending_source)
                    SOURCE_TOP: begin
                        raw_reference[scan_index] <= top_read_data;
                        if (scan_index == 17)
                            carried_top_left <= top_read_data;
                    end
                    SOURCE_LEFT:
                        raw_reference[scan_index] <=
                            left_edge[pending_left_index];
                    SOURCE_CORNER:
                        raw_reference[scan_index] <= carried_top_left;
                    default:
                        raw_reference[scan_index] <= 8'd128;
                endcase
                if (scan_index == 18) begin
                    state <= PREPARE_OUTPUT;
                end else begin
                    scan_index <= scan_index + 1'b1;
                    state <= SCAN_ISSUE;
                end
            end else if (state == PREPARE_OUTPUT) begin
                for (capture_index = 0; capture_index < 19;
                        capture_index = capture_index + 1) begin
                    filled_reference[capture_index] <=
                        filled_reference_next[capture_index];
                end
                output_index <= 4'd0;
                state <= OUTPUT_REFERENCES;
            end else if (output_fire) begin
                if (output_index == 9) begin
                    output_index <= 4'd0;
                    state <= WAIT_RECONSTRUCTION;
                end else begin
                    output_index <= output_index + 1'b1;
                end
            end

            if (recon_valid && (state != WAIT_RECONSTRUCTION))
                protocol_error <= 1'b1;

            if (recon_fire && recon_block_last) begin
                if ((recon_x != 7) || (recon_y != 7))
                    protocol_error <= 1'b1;
                block_committed <= 1'b1;
                state <= IDLE;
            end
        end
    end
endmodule
/* verilator lint_on WIDTHTRUNC */
/* verilator lint_on WIDTHEXPAND */
