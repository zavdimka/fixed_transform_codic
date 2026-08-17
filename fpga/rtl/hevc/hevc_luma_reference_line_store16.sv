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

    typedef enum logic [1:0] {
        IDLE,
        OUTPUT_REFERENCES,
        WAIT_RECONSTRUCTION
    } state_t;

    state_t state;
    logic [6:0] latched_ctu_x;
    logic latched_top_available;

    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    logic [7:0] top_line [0:FRAME_WIDTH-1];
    logic [7:0] left_edge [0:15];
    logic [7:0] carried_top_left;
    logic [7:0] first_top_sample;

    logic [4:0] issue_index;
    logic issue_done;
    logic read_valid;
    logic [4:0] read_index;
    logic [7:0] top_read_data;
    logic [ADDRESS_WIDTH-1:0] block_base;
    logic [ADDRESS_WIDTH:0] top_candidate_address;
    logic [ADDRESS_WIDTH-1:0] top_read_address;
    logic [ADDRESS_WIDTH-1:0] recon_address;
    logic [7:0] formatted_top;
    logic [7:0] formatted_left;

    wire geometry_valid = (FRAME_WIDTH >= 16) &&
        ((FRAME_WIDTH % 16) == 0) &&
        (CTU_COLUMNS == (FRAME_WIDTH / 16)) &&
        (CTU_COLUMNS > 0) && (CTU_COLUMNS <= 128);
    wire start_fire = start_valid && start_ready;
    wire output_fire = m_valid && m_ready;
    wire recon_fire = recon_valid && (state == WAIT_RECONSTRUCTION);
    wire output_stage_ready = !m_valid || m_ready;
    wire read_stage_ready = !read_valid || output_stage_ready;
    wire issue_fire = (state == OUTPUT_REFERENCES) && !issue_done &&
        read_stage_ready;

    assign block_base = latched_ctu_x << 4;
    assign top_candidate_address = {1'b0, block_base} +
        ((issue_index == 0) ? 0 : (issue_index - 1'b1));
    assign top_read_address = (top_candidate_address >= FRAME_WIDTH) ?
        ADDRESS_WIDTH'(FRAME_WIDTH - 1) :
        top_candidate_address[ADDRESS_WIDTH-1:0];
    assign recon_address = block_base + recon_x;
    assign start_ready = (state == IDLE) && geometry_valid;
    assign parameter_error = !geometry_valid;
    assign busy = state != IDLE;

    always_comb begin
        if (latched_top_available) begin
            if ((read_index == 0) && (latched_ctu_x != 0))
                formatted_top = carried_top_left;
            else
                formatted_top = top_read_data;
        end else if (latched_ctu_x != 0) begin
            formatted_top = left_edge[0];
        end else begin
            formatted_top = 8'd128;
        end

        if (read_index == 0) begin
            formatted_left = formatted_top;
        end else if (latched_ctu_x != 0) begin
            if (read_index <= 16)
                formatted_left = left_edge[read_index - 1'b1];
            else
                formatted_left = left_edge[15];
        end else if (latched_top_available) begin
            formatted_left = first_top_sample;
        end else begin
            formatted_left = 8'd128;
        end
    end

    always_ff @(posedge clk) begin
        if (issue_fire && latched_top_available)
            top_read_data <= top_line[top_read_address];
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
            first_top_sample <= 8'd128;
            issue_index <= 5'd0;
            issue_done <= 1'b0;
            read_valid <= 1'b0;
            read_index <= 5'd0;
            m_valid <= 1'b0;
            m_ref_top <= 8'd128;
            m_ref_left <= 8'd128;
            m_ref_last <= 1'b0;
            block_committed <= 1'b0;
            protocol_error <= 1'b0;
        end else begin
            block_committed <= 1'b0;

            if (output_stage_ready) begin
                m_valid <= read_valid;
                if (read_valid) begin
                    m_ref_top <= formatted_top;
                    m_ref_left <= formatted_left;
                    m_ref_last <= read_index == 18;
                    if (latched_top_available && (read_index == 0))
                        first_top_sample <= top_read_data;
                    if (latched_top_available && (read_index == 16))
                        carried_top_left <= top_read_data;
                end
            end

            if (read_stage_ready) begin
                read_valid <= issue_fire;
                if (issue_fire) begin
                    read_index <= issue_index;
                    if (issue_index == 18)
                        issue_done <= 1'b1;
                    else
                        issue_index <= issue_index + 1'b1;
                end
            end

            if (start_fire) begin
                latched_ctu_x <= ctu_x;
                latched_top_available <= top_available;
                issue_index <= 5'd0;
                issue_done <= 1'b0;
                read_valid <= 1'b0;
                m_valid <= 1'b0;
                protocol_error <= 1'b0;
                state <= OUTPUT_REFERENCES;
            end

            if (output_fire && m_ref_last) begin
                m_valid <= 1'b0;
                read_valid <= 1'b0;
                state <= WAIT_RECONSTRUCTION;
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
