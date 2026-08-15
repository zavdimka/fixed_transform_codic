/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
module hevc_camera_yuv420p_ingress #(
    parameter integer FRAME_WIDTH = 1280,
    parameter integer FRAME_HEIGHT = 768
) (
    input  logic       clk,
    input  logic       rst_n,

    // Planar 8-bit I420 byte stream: Y raster, then Cb raster, then Cr raster.
    input  logic       s_valid,
    output logic       s_ready,
    input  logic [7:0] s_data,
    input  logic       s_sof,

    // Block-raster output. Y blocks are 16x16; Cb/Cr blocks are 8x8.
    output logic       m_valid,
    input  logic       m_ready,
    output logic [7:0] m_data,
    output logic [1:0] m_plane,
    output logic [6:0] m_block_x,
    output logic [6:0] m_block_y,
    output logic [3:0] m_x,
    output logic [3:0] m_y,
    output logic       m_block_last,
    output logic       m_plane_last,
    output logic       m_frame_last,

    output logic       protocol_error,
    output logic       parameter_error,
    output logic       busy
);
    localparam integer STRIPE_SAMPLES = FRAME_WIDTH * 16;
    localparam integer ADDRESS_WIDTH = (STRIPE_SAMPLES <= 2) ? 1 :
        $clog2(STRIPE_SAMPLES);
    localparam integer INPUT_X_WIDTH = (FRAME_WIDTH <= 2) ? 1 :
        $clog2(FRAME_WIDTH);
    localparam integer BLOCK_COLUMNS = FRAME_WIDTH / 16;
    localparam integer BLOCK_ROWS = FRAME_HEIGHT / 16;

    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    logic [7:0] bank0 [0:STRIPE_SAMPLES-1];
    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    logic [7:0] bank1 [0:STRIPE_SAMPLES-1];

    logic write_bank;
    logic read_bank;
    logic [1:0] bank_full;
    logic [1:0] bank_plane [0:1];
    logic [6:0] bank_block_row [0:1];

    logic [1:0] input_plane;
    logic [INPUT_X_WIDTH-1:0] input_x;
    logic [3:0] input_line;
    logic [6:0] input_block_row;
    logic awaiting_sof;

    logic reader_active;
    logic [1:0] reader_plane;
    logic [6:0] reader_block_row;
    logic [6:0] reader_block_x;
    logic [3:0] reader_x;
    logic [3:0] reader_y;

    logic read_pending;
    logic [7:0] read_data;
    logic [1:0] read_plane_meta;
    logic [6:0] read_block_x_meta;
    logic [6:0] read_block_y_meta;
    logic [3:0] read_x_meta;
    logic [3:0] read_y_meta;
    logic read_block_last_meta;
    logic read_plane_last_meta;
    logic read_frame_last_meta;

    logic [7:0] fifo_data [0:1];
    logic [1:0] fifo_plane [0:1];
    logic [6:0] fifo_block_x [0:1];
    logic [6:0] fifo_block_y [0:1];
    logic [3:0] fifo_x [0:1];
    logic [3:0] fifo_y [0:1];
    logic [1:0] fifo_block_last;
    logic [1:0] fifo_plane_last;
    logic [1:0] fifo_frame_last;
    logic [1:0] fifo_count;

    integer input_plane_width;
    integer input_block_size;
    logic [ADDRESS_WIDTH-1:0] write_address;
    logic [ADDRESS_WIDTH-1:0] read_address;

    wire geometry_valid = (FRAME_WIDTH >= 16) && (FRAME_HEIGHT >= 16) &&
        ((FRAME_WIDTH % 16) == 0) && ((FRAME_HEIGHT % 16) == 0) &&
        (BLOCK_COLUMNS <= 128) && (BLOCK_ROWS <= 128);
    wire input_fire = s_valid && s_ready;
    wire output_fire = m_valid && m_ready;
    wire return_valid = read_pending;
    wire output_space = (fifo_count + read_pending - output_fire) < 2;
    wire issue_read = reader_active && output_space;

    always_comb begin
        input_plane_width = (input_plane == 0) ? FRAME_WIDTH :
            (FRAME_WIDTH / 2);
        input_block_size = (input_plane == 0) ? 16 : 8;
    end

    assign parameter_error = !geometry_valid;
    assign s_ready = geometry_valid && !bank_full[write_bank];
    assign m_valid = (fifo_count != 0);
    assign m_data = fifo_data[0];
    assign m_plane = fifo_plane[0];
    assign m_block_x = fifo_block_x[0];
    assign m_block_y = fifo_block_y[0];
    assign m_x = fifo_x[0];
    assign m_y = fifo_y[0];
    assign m_block_last = fifo_block_last[0];
    assign m_plane_last = fifo_plane_last[0];
    assign m_frame_last = fifo_frame_last[0];
    assign busy = !awaiting_sof || (bank_full != 0) || reader_active ||
        read_pending || (fifo_count != 0);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            write_bank <= 1'b0;
            read_bank <= 1'b0;
            bank_full <= 2'b00;
            bank_plane[0] <= 2'd0;
            bank_plane[1] <= 2'd0;
            bank_block_row[0] <= 7'd0;
            bank_block_row[1] <= 7'd0;
            input_plane <= 2'd0;
            input_x <= '0;
            input_line <= 4'd0;
            input_block_row <= 7'd0;
            write_address <= '0;
            awaiting_sof <= 1'b1;
            reader_active <= 1'b0;
            reader_plane <= 2'd0;
            reader_block_row <= 7'd0;
            reader_block_x <= 7'd0;
            reader_x <= 4'd0;
            reader_y <= 4'd0;
            read_address <= '0;
            read_pending <= 1'b0;
            read_data <= 8'd0;
            read_plane_meta <= 2'd0;
            read_block_x_meta <= 7'd0;
            read_block_y_meta <= 7'd0;
            read_x_meta <= 4'd0;
            read_y_meta <= 4'd0;
            read_block_last_meta <= 1'b0;
            read_plane_last_meta <= 1'b0;
            read_frame_last_meta <= 1'b0;
            fifo_count <= 2'd0;
            protocol_error <= 1'b0;
        end else begin
            if (input_fire) begin
                write_address <= write_address + 1'b1;
                if (awaiting_sof) begin
                    protocol_error <= !s_sof;
                    awaiting_sof <= 1'b0;
                end else if (s_sof) begin
                    protocol_error <= 1'b1;
                end

                if (write_bank)
                    bank1[write_address] <= s_data;
                else
                    bank0[write_address] <= s_data;

                if (input_x == input_plane_width - 1) begin
                    input_x <= '0;
                    if (input_line == input_block_size - 1) begin
                        input_line <= 4'd0;
                        write_address <= '0;
                        bank_full[write_bank] <= 1'b1;
                        bank_plane[write_bank] <= input_plane;
                        bank_block_row[write_bank] <= input_block_row;
                        write_bank <= !write_bank;

                        if (input_block_row == BLOCK_ROWS - 1) begin
                            input_block_row <= 7'd0;
                            if (input_plane == 2) begin
                                input_plane <= 2'd0;
                                awaiting_sof <= 1'b1;
                            end else begin
                                input_plane <= input_plane + 1'b1;
                            end
                        end else begin
                            input_block_row <= input_block_row + 1'b1;
                        end
                    end else begin
                        input_line <= input_line + 1'b1;
                    end
                end else begin
                    input_x <= input_x + 1'b1;
                end
            end

            if (!reader_active && bank_full[read_bank]) begin
                reader_active <= 1'b1;
                reader_plane <= bank_plane[read_bank];
                reader_block_row <= bank_block_row[read_bank];
                reader_block_x <= 7'd0;
                reader_x <= 4'd0;
                reader_y <= 4'd0;
                read_address <= '0;
            end

            if (issue_read) begin
                if (read_bank)
                    read_data <= bank1[read_address];
                else
                    read_data <= bank0[read_address];
                read_plane_meta <= reader_plane;
                read_block_x_meta <= reader_block_x;
                read_block_y_meta <= reader_block_row;
                read_x_meta <= reader_x;
                read_y_meta <= reader_y;
                read_block_last_meta <=
                    (reader_x == ((reader_plane == 0) ? 15 : 7)) &&
                    (reader_y == ((reader_plane == 0) ? 15 : 7));
                read_plane_last_meta <=
                    (reader_block_x == BLOCK_COLUMNS - 1) &&
                    (reader_block_row == BLOCK_ROWS - 1) &&
                    (reader_x == ((reader_plane == 0) ? 15 : 7)) &&
                    (reader_y == ((reader_plane == 0) ? 15 : 7));
                read_frame_last_meta <= (reader_plane == 2) &&
                    (reader_block_x == BLOCK_COLUMNS - 1) &&
                    (reader_block_row == BLOCK_ROWS - 1) &&
                    (reader_x == 7) && (reader_y == 7);

                if ((reader_x == ((reader_plane == 0) ? 15 : 7)) &&
                    (reader_y == ((reader_plane == 0) ? 15 : 7))) begin
                    reader_x <= 4'd0;
                    reader_y <= 4'd0;
                    if (reader_block_x == BLOCK_COLUMNS - 1) begin
                        reader_active <= 1'b0;
                        read_address <= '0;
                        bank_full[read_bank] <= 1'b0;
                        read_bank <= !read_bank;
                    end else begin
                        reader_block_x <= reader_block_x + 1'b1;
                        read_address <= read_address - ((reader_plane == 0) ?
                            (15 * FRAME_WIDTH - 1) :
                            (7 * (FRAME_WIDTH / 2) - 1));
                    end
                end else if (reader_x == ((reader_plane == 0) ? 15 : 7)) begin
                    reader_x <= 4'd0;
                    reader_y <= reader_y + 1'b1;
                    read_address <= read_address + ((reader_plane == 0) ?
                        (FRAME_WIDTH - 15) : ((FRAME_WIDTH / 2) - 7));
                end else begin
                    reader_x <= reader_x + 1'b1;
                    read_address <= read_address + 1'b1;
                end
            end
            read_pending <= issue_read;

            case ({return_valid, output_fire})
                2'b10: begin
                    if (fifo_count == 0) begin
                        fifo_data[0] <= read_data;
                        fifo_plane[0] <= read_plane_meta;
                        fifo_block_x[0] <= read_block_x_meta;
                        fifo_block_y[0] <= read_block_y_meta;
                        fifo_x[0] <= read_x_meta;
                        fifo_y[0] <= read_y_meta;
                        fifo_block_last[0] <= read_block_last_meta;
                        fifo_plane_last[0] <= read_plane_last_meta;
                        fifo_frame_last[0] <= read_frame_last_meta;
                    end else begin
                        fifo_data[1] <= read_data;
                        fifo_plane[1] <= read_plane_meta;
                        fifo_block_x[1] <= read_block_x_meta;
                        fifo_block_y[1] <= read_block_y_meta;
                        fifo_x[1] <= read_x_meta;
                        fifo_y[1] <= read_y_meta;
                        fifo_block_last[1] <= read_block_last_meta;
                        fifo_plane_last[1] <= read_plane_last_meta;
                        fifo_frame_last[1] <= read_frame_last_meta;
                    end
                    fifo_count <= fifo_count + 1'b1;
                end
                2'b01: begin
                    if (fifo_count == 2) begin
                        fifo_data[0] <= fifo_data[1];
                        fifo_plane[0] <= fifo_plane[1];
                        fifo_block_x[0] <= fifo_block_x[1];
                        fifo_block_y[0] <= fifo_block_y[1];
                        fifo_x[0] <= fifo_x[1];
                        fifo_y[0] <= fifo_y[1];
                        fifo_block_last[0] <= fifo_block_last[1];
                        fifo_plane_last[0] <= fifo_plane_last[1];
                        fifo_frame_last[0] <= fifo_frame_last[1];
                    end
                    fifo_count <= fifo_count - 1'b1;
                end
                2'b11: begin
                    if (fifo_count == 1) begin
                        fifo_data[0] <= read_data;
                        fifo_plane[0] <= read_plane_meta;
                        fifo_block_x[0] <= read_block_x_meta;
                        fifo_block_y[0] <= read_block_y_meta;
                        fifo_x[0] <= read_x_meta;
                        fifo_y[0] <= read_y_meta;
                        fifo_block_last[0] <= read_block_last_meta;
                        fifo_plane_last[0] <= read_plane_last_meta;
                        fifo_frame_last[0] <= read_frame_last_meta;
                    end else begin
                        fifo_data[0] <= fifo_data[1];
                        fifo_plane[0] <= fifo_plane[1];
                        fifo_block_x[0] <= fifo_block_x[1];
                        fifo_block_y[0] <= fifo_block_y[1];
                        fifo_x[0] <= fifo_x[1];
                        fifo_y[0] <= fifo_y[1];
                        fifo_block_last[0] <= fifo_block_last[1];
                        fifo_plane_last[0] <= fifo_plane_last[1];
                        fifo_frame_last[0] <= fifo_frame_last[1];
                        fifo_data[1] <= read_data;
                        fifo_plane[1] <= read_plane_meta;
                        fifo_block_x[1] <= read_block_x_meta;
                        fifo_block_y[1] <= read_block_y_meta;
                        fifo_x[1] <= read_x_meta;
                        fifo_y[1] <= read_y_meta;
                        fifo_block_last[1] <= read_block_last_meta;
                        fifo_plane_last[1] <= read_plane_last_meta;
                        fifo_frame_last[1] <= read_frame_last_meta;
                    end
                end
                default: begin
                end
            endcase
        end
    end
endmodule
/* verilator lint_on WIDTHTRUNC */
/* verilator lint_on WIDTHEXPAND */
