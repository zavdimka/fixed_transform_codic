module hevc_coefficient_scan8 (
    input logic clk, input logic rst_n,
    input logic s_valid, output logic s_ready,
    input logic [5:0] s_raster_address, input logic signed [15:0] s_coefficient,
    input logic s_block_last,
    output logic m_valid, input logic m_ready,
    output logic signed [15:0] m_coefficient,
    output logic [5:0] m_raster_address, output logic [5:0] m_scan_position,
    output logic [1:0] m_group_scan_position, output logic [3:0] m_position_in_group,
    output logic m_block_last, output logic m_nonzero, output logic m_group_nonzero,
    output logic [3:0] significant_group_flags, output logic any_nonzero,
    output logic [5:0] last_nonzero_scan_position,
    output logic busy, output logic input_error
);
    typedef enum logic {LOAD, SCAN} state_t;
    state_t state;
    logic signed [15:0] memory [0:63];
    logic [3:0] group_flags;
    logic [5:0] load_count, issue_position;

    function automatic logic [3:0] diagonal4(input logic [3:0] i);
        case (i) 0:diagonal4=0;1:diagonal4=4;2:diagonal4=1;3:diagonal4=8;
          4:diagonal4=5;5:diagonal4=2;6:diagonal4=12;7:diagonal4=9;
          8:diagonal4=6;9:diagonal4=3;10:diagonal4=13;11:diagonal4=10;
          12:diagonal4=7;13:diagonal4=14;14:diagonal4=11;default:diagonal4=15; endcase
    endfunction
    function automatic logic [3:0] inverse4(input logic [3:0] r);
        case (r) 0:inverse4=0;1:inverse4=2;2:inverse4=5;3:inverse4=9;
          4:inverse4=1;5:inverse4=4;6:inverse4=8;7:inverse4=12;
          8:inverse4=3;9:inverse4=7;10:inverse4=11;11:inverse4=14;
          12:inverse4=6;13:inverse4=10;14:inverse4=13;default:inverse4=15; endcase
    endfunction
    function automatic logic [1:0] diagonal2(input logic [1:0] i);
        case (i) 0:diagonal2=0;1:diagonal2=2;2:diagonal2=1;default:diagonal2=3; endcase
    endfunction
    function automatic logic [1:0] inverse2(input logic [1:0] r);
        case (r) 0:inverse2=0;1:inverse2=2;2:inverse2=1;default:inverse2=3; endcase
    endfunction
    function automatic logic [5:0] scan_to_raster(input logic [5:0] p);
        logic [1:0] gr; logic [3:0] lr;
        begin
            gr = diagonal2(p[5:4]); lr = diagonal4(p[3:0]);
            scan_to_raster = {gr[1], lr[3:2], gr[0], lr[1:0]};
        end
    endfunction

    wire [1:0] write_group_raster = {s_raster_address[5], s_raster_address[2]};
    wire [3:0] write_local_raster = {s_raster_address[4:3], s_raster_address[1:0]};
    wire [5:0] write_scan_position = {inverse2(write_group_raster), inverse4(write_local_raster)};
    wire [5:0] active_address = scan_to_raster(issue_position);
    wire output_advance = !m_valid || m_ready;

    assign s_ready = state == LOAD;
    assign busy = state == SCAN;
    assign significant_group_flags = group_flags;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= LOAD; load_count <= 0; issue_position <= 0; m_valid <= 0;
            m_coefficient <= 0; m_raster_address <= 0; m_scan_position <= 0;
            m_group_scan_position <= 0; m_position_in_group <= 0;
            m_block_last <= 0; m_nonzero <= 0; m_group_nonzero <= 0;
            group_flags <= 0; any_nonzero <= 0; last_nonzero_scan_position <= 0;
            input_error <= 0;
        end else if (state == LOAD) begin
            m_valid <= 0;
            if (s_valid) begin
                memory[s_raster_address] <= s_coefficient;
                if (s_coefficient != 0) begin
                    group_flags[write_group_raster] <= 1'b1;
                    any_nonzero <= 1'b1;
                    if (!any_nonzero || write_scan_position > last_nonzero_scan_position)
                        last_nonzero_scan_position <= write_scan_position;
                end
                if (s_block_last || load_count == 63) begin
                    input_error <= s_block_last != (load_count == 63);
                    issue_position <= (s_coefficient != 0 &&
                        (!any_nonzero || write_scan_position > last_nonzero_scan_position))
                        ? write_scan_position : last_nonzero_scan_position;
                    state <= SCAN;
                end else load_count <= load_count + 1'b1;
            end
        end else if (output_advance) begin
            m_valid <= 1'b1;
            m_coefficient <= memory[active_address];
            m_raster_address <= active_address;
            m_scan_position <= issue_position;
            m_group_scan_position <= issue_position[5:4];
            m_position_in_group <= issue_position[3:0];
            m_block_last <= issue_position == 0;
            m_nonzero <= memory[active_address] != 0;
            m_group_nonzero <= group_flags[diagonal2(issue_position[5:4])];
            if (m_valid && m_ready && m_block_last) begin
                state <= LOAD; load_count <= 0; m_valid <= 0; group_flags <= 0;
                any_nonzero <= 0; last_nonzero_scan_position <= 0; input_error <= 0;
            end else if (issue_position != 0) issue_position <= issue_position - 1'b1;
        end
    end
endmodule
