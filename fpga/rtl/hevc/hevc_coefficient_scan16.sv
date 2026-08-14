module hevc_coefficient_scan16 (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               s_valid,
    output logic               s_ready,
    input  logic [7:0]         s_raster_address,
    input  logic signed [15:0] s_coefficient,
    input  logic               s_block_last,
    output logic               m_valid,
    input  logic               m_ready,
    output logic signed [15:0] m_coefficient,
    output logic [7:0]         m_raster_address,
    output logic [7:0]         m_scan_position,
    output logic [3:0]         m_group_scan_position,
    output logic [3:0]         m_position_in_group,
    output logic               m_group_first,
    output logic               m_group_last,
    output logic               m_block_last,
    output logic               m_nonzero,
    output logic               m_group_nonzero,
    output logic               any_nonzero,
    output logic [7:0]         last_nonzero_scan_position,
    output logic               busy,
    output logic               input_error
);
    typedef enum logic {LOAD, SCAN} state_t;
    state_t state;

    logic [15:0] group_nonzero;
    logic [7:0] load_count;
    logic [7:0] issue_position;
    logic issue_complete;
    logic read_pending;
    logic signed [15:0] ram_read_data;
    logic [7:0] pending_raster_address;
    logic [7:0] pending_scan_position;

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

    function automatic logic [3:0] inverse_diagonal4(input logic [3:0] raster);
        case (raster)
            4'd0: inverse_diagonal4 = 4'd0;
            4'd1: inverse_diagonal4 = 4'd2;
            4'd2: inverse_diagonal4 = 4'd5;
            4'd3: inverse_diagonal4 = 4'd9;
            4'd4: inverse_diagonal4 = 4'd1;
            4'd5: inverse_diagonal4 = 4'd4;
            4'd6: inverse_diagonal4 = 4'd8;
            4'd7: inverse_diagonal4 = 4'd12;
            4'd8: inverse_diagonal4 = 4'd3;
            4'd9: inverse_diagonal4 = 4'd7;
            4'd10: inverse_diagonal4 = 4'd11;
            4'd11: inverse_diagonal4 = 4'd14;
            4'd12: inverse_diagonal4 = 4'd6;
            4'd13: inverse_diagonal4 = 4'd10;
            4'd14: inverse_diagonal4 = 4'd13;
            default: inverse_diagonal4 = 4'd15;
        endcase
    endfunction

    function automatic logic [7:0] scan_to_raster(input logic [7:0] position);
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

    wire [3:0] write_group_raster = {
        s_raster_address[7:6], s_raster_address[3:2]
    };
    wire [3:0] write_local_raster = {
        s_raster_address[5:4], s_raster_address[1:0]
    };
    wire [7:0] write_scan_position = {
        inverse_diagonal4(write_group_raster),
        inverse_diagonal4(write_local_raster)
    };

    assign s_ready = (state == LOAD);
    assign busy = (state == SCAN);

    wire output_advance = !m_valid || m_ready;
    wire ram_read_enable = (state == SCAN) && output_advance && !issue_complete;
    wire [7:0] ram_read_address = scan_to_raster(issue_position);

    hevc_coefficient_buffer16 coefficient_buffer (
        .clk(clk),
        .write_enable(s_valid && s_ready),
        .write_address(s_raster_address),
        .write_data(s_coefficient),
        .read_enable(ram_read_enable),
        .read_address(ram_read_address),
        .read_data(ram_read_data)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= LOAD;
            load_count <= 8'd0;
            issue_position <= 8'd0;
            issue_complete <= 1'b0;
            read_pending <= 1'b0;
            m_valid <= 1'b0;
            m_coefficient <= '0;
            m_raster_address <= '0;
            m_scan_position <= '0;
            m_group_scan_position <= '0;
            m_position_in_group <= '0;
            m_group_first <= 1'b0;
            m_group_last <= 1'b0;
            m_block_last <= 1'b0;
            m_nonzero <= 1'b0;
            m_group_nonzero <= 1'b0;
            group_nonzero <= '0;
            any_nonzero <= 1'b0;
            last_nonzero_scan_position <= '0;
            input_error <= 1'b0;
        end else if (state == LOAD) begin
            m_valid <= 1'b0;
            read_pending <= 1'b0;
            if (s_valid) begin
                if (s_coefficient != 0) begin
                    group_nonzero[write_group_raster] <= 1'b1;
                    any_nonzero <= 1'b1;
                    if (!any_nonzero ||
                            (write_scan_position > last_nonzero_scan_position)) begin
                        last_nonzero_scan_position <= write_scan_position;
                    end
                end

                if (s_block_last || (load_count == 8'hff)) begin
                    input_error <= (s_block_last != (load_count == 8'hff));
                    state <= SCAN;
                    if ((s_coefficient != 0) && (!any_nonzero ||
                            (write_scan_position > last_nonzero_scan_position))) begin
                        issue_position <= write_scan_position;
                    end else begin
                        issue_position <= last_nonzero_scan_position;
                    end
                    issue_complete <= 1'b0;
                    read_pending <= 1'b0;
                end else begin
                    load_count <= load_count + 1'b1;
                end
            end
        end else begin
            if (m_valid && m_ready && m_block_last) begin
                state <= LOAD;
                load_count <= 8'd0;
                issue_position <= 8'd0;
                issue_complete <= 1'b0;
                read_pending <= 1'b0;
                m_valid <= 1'b0;
                group_nonzero <= '0;
                any_nonzero <= 1'b0;
                last_nonzero_scan_position <= '0;
                input_error <= 1'b0;
            end else if (!m_valid || m_ready) begin
                m_valid <= read_pending;
                if (read_pending) begin
                    m_coefficient <= ram_read_data;
                    m_raster_address <= pending_raster_address;
                    m_scan_position <= pending_scan_position;
                    m_group_scan_position <= pending_scan_position[7:4];
                    m_position_in_group <= pending_scan_position[3:0];
                    m_group_first <= (pending_scan_position[3:0] == 4'd0);
                    m_group_last <= (pending_scan_position[3:0] == 4'd15);
                    m_block_last <= (pending_scan_position == 8'd0);
                    m_nonzero <= (ram_read_data != 0);
                    m_group_nonzero <= group_nonzero[
                        diagonal4(pending_scan_position[7:4])
                    ];
                end

                if (!issue_complete) begin
                    pending_raster_address <= scan_to_raster(issue_position);
                    pending_scan_position <= issue_position;
                    read_pending <= 1'b1;
                    if (issue_position == 8'd0) begin
                        issue_complete <= 1'b1;
                    end else begin
                        issue_position <= issue_position - 1'b1;
                    end
                end else begin
                    read_pending <= 1'b0;
                end
            end
        end
    end
endmodule
