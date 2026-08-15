module hevc_luma_reference_line_store (
    input  logic       clk,
    input  logic       rst_n,

    input  logic       start_valid,
    output logic       start_ready,
    input  logic [5:0] ctu_x,
    input  logic [3:0] cu_index,

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
    output logic       busy
);
    typedef enum logic [2:0] {
        IDLE,
        SCAN_ISSUE,
        SCAN_CAPTURE,
        PREPARE_OUTPUT,
        OUTPUT_REFERENCES,
        WAIT_RECONSTRUCTION
    } state_t;

    localparam logic [1:0] SOURCE_NONE = 2'd0;
    localparam logic [1:0] SOURCE_BOTTOM = 2'd1;
    localparam logic [1:0] SOURCE_RIGHT = 2'd2;

    state_t state;
    logic [5:0] latched_ctu_x;
    logic [3:0] latched_cu_index;
    logic [1:0] block_x;
    logic [1:0] block_y;
    logic [3:0] block_raster;
    logic [15:0] completed_blocks;

    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    logic [7:0] bottom_edges [0:255];
    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    logic [7:0] right_edges [0:319];

    logic bottom_read_enable;
    logic [7:0] bottom_read_address;
    logic [7:0] bottom_read_data;
    logic right_read_enable;
    logic [8:0] right_read_address;
    logic [7:0] right_read_data;

    logic bottom_write_enable;
    logic [7:0] bottom_write_address;
    logic right_write_enable;
    logic [8:0] right_write_address;

    logic [5:0] scan_index;
    logic [5:0] output_index;
    logic [7:0] raw_reference [0:36];
    logic raw_available [0:36];
    logic [7:0] filled_reference [0:36];

    logic candidate_available;
    logic [1:0] candidate_source;
    logic [8:0] candidate_address;
    logic pending_available;
    logic [1:0] pending_source;

    integer sample_offset;
    integer sample_block_x;
    integer sample_block_y;
    integer sample_local;
    integer sample_raster;
    integer fill_index;
    logic [7:0] first_available_sample;
    logic [7:0] running_sample;
    logic found_available;

    wire start_fire = start_valid && start_ready;
    wire output_fire = m_valid && m_ready;
    wire recon_fire = recon_valid && (state == WAIT_RECONSTRUCTION);

    assign block_x = {latched_cu_index[2], latched_cu_index[0]};
    assign block_y = {latched_cu_index[3], latched_cu_index[1]};
    assign block_raster = {block_y, block_x};
    assign start_ready = state == IDLE;
    assign busy = state != IDLE;
    assign m_valid = state == OUTPUT_REFERENCES;
    assign m_ref_last = output_index == 18;
    assign m_ref_top = (output_index == 0) ?
        filled_reference[18] : filled_reference[18 + output_index];
    assign m_ref_left = (output_index == 0) ?
        filled_reference[18] : filled_reference[18 - output_index];
    /* verilator lint_off WIDTHEXPAND */

    always_comb begin
        candidate_available = 1'b0;
        candidate_source = SOURCE_NONE;
        candidate_address = 9'd0;
        sample_offset = 0;
        sample_block_x = 0;
        sample_block_y = 0;
        sample_local = 0;
        sample_raster = 0;

        if (scan_index < 18) begin
            // Scan from bottom-left towards the shared top-left sample.
            sample_offset = 17 - $unsigned(scan_index);
            sample_block_y = $unsigned(block_y) + (sample_offset >> 4);
            sample_local = sample_offset & 15;
            if (block_x == 0) begin
                if ((latched_ctu_x != 0) && (sample_block_y < 4)) begin
                    candidate_available = 1'b1;
                    candidate_source = SOURCE_RIGHT;
                    candidate_address = 9'(256 +
                        (sample_block_y << 4) + sample_local);
                end
            end else if (sample_block_y < 4) begin
                sample_block_x = $unsigned(block_x) - 1;
                sample_raster = (sample_block_y << 2) + sample_block_x;
                if (completed_blocks[sample_raster]) begin
                    candidate_available = 1'b1;
                    candidate_source = SOURCE_RIGHT;
                    candidate_address = 9'((sample_raster << 4) + sample_local);
                end
            end
        end else if (scan_index == 18) begin
            // Shared top-left reference.
            if (block_y != 0) begin
                if (block_x == 0) begin
                    if (latched_ctu_x != 0) begin
                        candidate_available = 1'b1;
                        candidate_source = SOURCE_RIGHT;
                        candidate_address = 9'(256 +
                            ($unsigned(block_y) << 4) - 1);
                    end
                end else begin
                    sample_raster = (($unsigned(block_y) - 1) << 2) +
                        ($unsigned(block_x) - 1);
                    if (completed_blocks[sample_raster]) begin
                        candidate_available = 1'b1;
                        candidate_source = SOURCE_BOTTOM;
                        candidate_address = 9'((sample_raster << 4) + 15);
                    end
                end
            end
        end else begin
            // Scan from the first top sample towards top-right.
            sample_offset = $unsigned(scan_index) - 19;
            if (block_y != 0) begin
                sample_block_x = $unsigned(block_x) + (sample_offset >> 4);
                sample_local = sample_offset & 15;
                if (sample_block_x < 4) begin
                    sample_block_y = $unsigned(block_y) - 1;
                    sample_raster = (sample_block_y << 2) + sample_block_x;
                    if (completed_blocks[sample_raster]) begin
                        candidate_available = 1'b1;
                        candidate_source = SOURCE_BOTTOM;
                        candidate_address = 9'((sample_raster << 4) + sample_local);
                    end
                end
            end
        end
    end

    assign bottom_read_enable = (state == SCAN_ISSUE) &&
        candidate_available && (candidate_source == SOURCE_BOTTOM);
    assign bottom_read_address = candidate_address[7:0];
    assign right_read_enable = (state == SCAN_ISSUE) &&
        candidate_available && (candidate_source == SOURCE_RIGHT);
    assign right_read_address = candidate_address;

    assign bottom_write_enable = recon_fire && (recon_y == 15);
    assign bottom_write_address = {block_raster, recon_x};
    assign right_write_enable = recon_fire && (recon_x == 15);
    assign right_write_address = (block_x == 3) ?
        (9'(256 + $unsigned({block_y, recon_y}))) : {1'b0, block_raster, recon_y};
    /* verilator lint_on WIDTHEXPAND */

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
        if (bottom_read_enable)
            bottom_read_data <= bottom_edges[bottom_read_address];
        if (right_read_enable)
            right_read_data <= right_edges[right_read_address];
        if (bottom_write_enable)
            bottom_edges[bottom_write_address] <= recon_pixel;
        if (right_write_enable)
            right_edges[right_write_address] <= recon_pixel;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            latched_ctu_x <= 6'd0;
            latched_cu_index <= 4'd0;
            completed_blocks <= 16'd0;
            scan_index <= 6'd0;
            output_index <= 6'd0;
            pending_available <= 1'b0;
            pending_source <= SOURCE_NONE;
            block_committed <= 1'b0;
            protocol_error <= 1'b0;
        end else begin
            block_committed <= 1'b0;

            if (start_fire) begin
                latched_ctu_x <= ctu_x;
                latched_cu_index <= cu_index;
                scan_index <= 6'd0;
                output_index <= 6'd0;
                protocol_error <= 1'b0;
                if (cu_index == 0)
                    completed_blocks <= 16'd0;
                state <= SCAN_ISSUE;
            end

            if (state == SCAN_ISSUE) begin
                pending_available <= candidate_available;
                pending_source <= candidate_source;
                state <= SCAN_CAPTURE;
            end else if (state == SCAN_CAPTURE) begin
                raw_available[scan_index] <= pending_available;
                case (pending_source)
                    SOURCE_BOTTOM:
                        raw_reference[scan_index] <= bottom_read_data;
                    SOURCE_RIGHT:
                        raw_reference[scan_index] <= right_read_data;
                    default:
                        raw_reference[scan_index] <= 8'd128;
                endcase
                if (scan_index == 36) begin
                    state <= PREPARE_OUTPUT;
                end else begin
                    scan_index <= scan_index + 1'b1;
                    state <= SCAN_ISSUE;
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
                completed_blocks[block_raster] <= 1'b1;
                block_committed <= 1'b1;
                state <= IDLE;
            end
        end
    end
endmodule
