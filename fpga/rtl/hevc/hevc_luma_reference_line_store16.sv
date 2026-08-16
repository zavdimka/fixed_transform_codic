/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
module hevc_luma_reference_line_store16 #(
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
    input  logic [3:0] recon_x,
    input  logic [3:0] recon_y,
    input  logic       recon_block_last,

    output logic       block_committed,
    output logic       protocol_error,
    output logic       parameter_error,
    output logic       busy
);
    localparam integer ADDRESS_WIDTH = (FRAME_WIDTH <= 2) ? 1 :
        $clog2(FRAME_WIDTH);

    typedef enum logic [2:0] {
        IDLE,
        SCAN_REFERENCES,
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
    logic [7:0] top_line [0:FRAME_WIDTH-1];
    logic [7:0] left_edge [0:15];
    logic [7:0] carried_top_left;

    logic [5:0] scan_index;
    logic [5:0] output_index;
    logic [7:0] raw_reference [0:36];
    logic raw_available [0:36];
    logic [7:0] filled_reference [0:36];

    logic candidate_available;
    logic [2:0] candidate_source;
    logic [ADDRESS_WIDTH-1:0] candidate_address;
    logic [3:0] candidate_left_index;
    logic pending_available;
    logic [2:0] pending_source;
    logic [3:0] pending_left_index;
    logic [5:0] pending_scan_index;
    logic pending_valid;
    logic scan_issue_done;
    logic [7:0] top_read_data;

    logic [ADDRESS_WIDTH-1:0] block_base;
    logic [ADDRESS_WIDTH-1:0] recon_address;
    integer sample_offset;
    integer fill_index;
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

    assign block_base = latched_ctu_x << 4;
    assign recon_address = block_base + recon_x;
    assign start_ready = (state == IDLE) && geometry_valid;
    assign parameter_error = !geometry_valid;
    assign busy = state != IDLE;
    assign m_valid = state == OUTPUT_REFERENCES;
    assign m_ref_last = output_index == 18;
    assign m_ref_top = (output_index == 0) ?
        filled_reference[18] : filled_reference[18 + output_index];
    assign m_ref_left = (output_index == 0) ?
        filled_reference[18] : filled_reference[18 - output_index];

    always_comb begin
        candidate_available = 1'b0;
        candidate_source = SOURCE_NONE;
        candidate_address = '0;
        candidate_left_index = 4'd0;
        sample_offset = 0;

        if (scan_index < 18) begin
            // bottom-left to the sample immediately below top-left
            sample_offset = 17 - scan_index;
            if ((latched_ctu_x != 0) && (sample_offset < 16)) begin
                candidate_available = 1'b1;
                candidate_source = SOURCE_LEFT;
                candidate_left_index = sample_offset[3:0];
            end
        end else if (scan_index == 18) begin
            if (latched_top_available && (latched_ctu_x != 0)) begin
                candidate_available = 1'b1;
                candidate_source = SOURCE_CORNER;
            end
        end else begin
            // first top sample through two top-right extension samples
            sample_offset = scan_index - 19;
            if (latched_top_available &&
                ((block_base + sample_offset) < FRAME_WIDTH)) begin
                candidate_available = 1'b1;
                candidate_source = SOURCE_TOP;
                candidate_address = block_base + sample_offset;
            end
        end
    end

    always_comb begin
        first_available_sample = 8'd128;
        found_available = 1'b0;
        for (fill_index = 0; fill_index < 37; fill_index = fill_index + 1) begin
            if (!found_available && raw_available[fill_index]) begin
                first_available_sample = raw_reference[fill_index];
                found_available = 1'b1;
            end
        end

        running_sample = first_available_sample;
        for (fill_index = 0; fill_index < 37; fill_index = fill_index + 1) begin
            if (raw_available[fill_index])
                running_sample = raw_reference[fill_index];
            filled_reference[fill_index] = running_sample;
        end
    end

    always_ff @(posedge clk) begin
        if ((state == SCAN_REFERENCES) && !scan_issue_done &&
            candidate_available &&
            (candidate_source == SOURCE_TOP))
            top_read_data <= top_line[candidate_address];
        if (recon_fire && (recon_y == 15))
            top_line[recon_address] <= recon_pixel;
        if (recon_fire && (recon_x == 15))
            left_edge[recon_y] <= recon_pixel;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            latched_ctu_x <= 7'd0;
            latched_top_available <= 1'b0;
            carried_top_left <= 8'd128;
            scan_index <= 6'd0;
            output_index <= 6'd0;
            pending_available <= 1'b0;
            pending_source <= SOURCE_NONE;
            pending_left_index <= 4'd0;
            pending_scan_index <= 6'd0;
            pending_valid <= 1'b0;
            scan_issue_done <= 1'b0;
            block_committed <= 1'b0;
            protocol_error <= 1'b0;
        end else begin
            block_committed <= 1'b0;

            if (start_fire) begin
                latched_ctu_x <= ctu_x;
                latched_top_available <= top_available;
                scan_index <= 6'd0;
                output_index <= 6'd0;
                protocol_error <= 1'b0;
                pending_valid <= 1'b0;
                scan_issue_done <= 1'b0;
                state <= SCAN_REFERENCES;
            end

            if (state == SCAN_REFERENCES) begin
                if (pending_valid) begin
                    raw_available[pending_scan_index] <= pending_available;
                    case (pending_source)
                        SOURCE_TOP: begin
                            raw_reference[pending_scan_index] <= top_read_data;
                            if (pending_scan_index == 34)
                                carried_top_left <= top_read_data;
                        end
                        SOURCE_LEFT:
                            raw_reference[pending_scan_index] <=
                                left_edge[pending_left_index];
                        SOURCE_CORNER:
                            raw_reference[pending_scan_index] <= carried_top_left;
                        default:
                            raw_reference[pending_scan_index] <= 8'd128;
                    endcase
                    if (pending_scan_index == 36) begin
                        pending_valid <= 1'b0;
                        state <= PREPARE_OUTPUT;
                    end
                end

                if (!scan_issue_done) begin
                    pending_available <= candidate_available;
                    pending_source <= candidate_source;
                    pending_left_index <= candidate_left_index;
                    pending_scan_index <= scan_index;
                    pending_valid <= 1'b1;
                    if (scan_index == 36)
                        scan_issue_done <= 1'b1;
                    else
                        scan_index <= scan_index + 1'b1;
                end
            end else if (state == PREPARE_OUTPUT) begin
                output_index <= 6'd0;
                state <= OUTPUT_REFERENCES;
            end else if (output_fire) begin
                if (output_index == 18) begin
                    output_index <= 6'd0;
                    state <= WAIT_RECONSTRUCTION;
                end else begin
                    output_index <= output_index + 1'b1;
                end
            end

            if (recon_valid && (state != WAIT_RECONSTRUCTION))
                protocol_error <= 1'b1;

            if (recon_fire && recon_block_last) begin
                if ((recon_x != 15) || (recon_y != 15))
                    protocol_error <= 1'b1;
                block_committed <= 1'b1;
                state <= IDLE;
            end
        end
    end
endmodule
/* verilator lint_on WIDTHTRUNC */
/* verilator lint_on WIDTHEXPAND */
