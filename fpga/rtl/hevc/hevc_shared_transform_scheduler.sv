module hevc_shared_transform_scheduler (
    input  logic               clk,
    input  logic               rst_n,

    input  logic               y_request_valid,
    output logic               y_request_ready,
    input  logic               y_inverse,
    input  logic               y_s_valid,
    output logic               y_s_ready,
    input  logic signed [15:0] y_s_data,
    output logic               y_m_valid,
    input  logic               y_m_ready,
    output logic signed [15:0] y_m_data,
    output logic [3:0]         y_m_x,
    output logic [3:0]         y_m_y,
    output logic               y_m_block_last,

    input  logic               cb_request_valid,
    output logic               cb_request_ready,
    input  logic               cb_inverse,
    input  logic               cb_s_valid,
    output logic               cb_s_ready,
    input  logic signed [15:0] cb_s_data,
    output logic               cb_m_valid,
    input  logic               cb_m_ready,
    output logic signed [15:0] cb_m_data,
    output logic [2:0]         cb_m_x,
    output logic [2:0]         cb_m_y,
    output logic               cb_m_block_last,

    input  logic               cr_request_valid,
    output logic               cr_request_ready,
    input  logic               cr_inverse,
    input  logic               cr_s_valid,
    output logic               cr_s_ready,
    input  logic signed [15:0] cr_s_data,
    output logic               cr_m_valid,
    input  logic               cr_m_ready,
    output logic signed [15:0] cr_m_data,
    output logic [2:0]         cr_m_x,
    output logic [2:0]         cr_m_y,
    output logic               cr_m_block_last,

    output logic               service_command_valid,
    input  logic               service_command_ready,
    output logic               service_size8,
    output logic               service_inverse,
    output logic [1:0]         service_plane,
    output logic               service_s_valid,
    input  logic               service_s_ready,
    output logic signed [15:0] service_s_data,
    input  logic               service_m_valid,
    output logic               service_m_ready,
    input  logic signed [15:0] service_m_data,
    input  logic [3:0]         service_m_x,
    input  logic [3:0]         service_m_y,
    input  logic               service_m_block_last,

    output logic               block_done,
    output logic [1:0]         completed_plane,
    output logic               protocol_error,
    output logic               busy
);
    localparam logic [1:0] PLANE_Y  = 2'd0;
    localparam logic [1:0] PLANE_CB = 2'd1;
    localparam logic [1:0] PLANE_CR = 2'd2;

    logic active;
    logic [1:0] active_plane;
    logic [8:0] input_count;
    logic [8:0] output_count;

    logic selected_valid;
    logic [1:0] selected_plane;
    logic selected_inverse;
    logic selected_size8;

    wire command_fire = service_command_valid && service_command_ready;
    wire input_fire = service_s_valid && service_s_ready;
    wire output_fire = service_m_valid && service_m_ready;
    wire [8:0] expected_last_index = active_plane == PLANE_Y ?
        9'd255 : 9'd63;
    wire [8:0] expected_input_count = active_plane == PLANE_Y ?
        9'd256 : 9'd64;
    wire input_complete = (input_count == expected_input_count) ||
        (input_fire && (input_count == expected_last_index));

    always_comb begin
        selected_valid = 1'b0;
        selected_plane = PLANE_Y;
        selected_inverse = 1'b0;
        selected_size8 = 1'b0;
        if (y_request_valid) begin
            selected_valid = 1'b1;
            selected_plane = PLANE_Y;
            selected_inverse = y_inverse;
        end else if (cb_request_valid) begin
            selected_valid = 1'b1;
            selected_plane = PLANE_CB;
            selected_inverse = cb_inverse;
            selected_size8 = 1'b1;
        end else if (cr_request_valid) begin
            selected_valid = 1'b1;
            selected_plane = PLANE_CR;
            selected_inverse = cr_inverse;
            selected_size8 = 1'b1;
        end
    end

    always_comb begin
        y_request_ready = 1'b0;
        cb_request_ready = 1'b0;
        cr_request_ready = 1'b0;
        service_command_valid = !active && selected_valid;
        service_size8 = selected_size8;
        service_inverse = selected_inverse;
        service_plane = selected_plane;
        if (!active && service_command_ready) begin
            case (selected_plane)
                PLANE_Y:  y_request_ready = selected_valid;
                PLANE_CB: cb_request_ready = selected_valid;
                PLANE_CR: cr_request_ready = selected_valid;
                default: begin end
            endcase
        end
    end

    always_comb begin
        service_s_valid = 1'b0;
        service_s_data = '0;
        y_s_ready = 1'b0;
        cb_s_ready = 1'b0;
        cr_s_ready = 1'b0;
        if (active) begin
            case (active_plane)
                PLANE_Y: begin
                    service_s_valid = y_s_valid;
                    service_s_data = y_s_data;
                    y_s_ready = service_s_ready;
                end
                PLANE_CB: begin
                    service_s_valid = cb_s_valid;
                    service_s_data = cb_s_data;
                    cb_s_ready = service_s_ready;
                end
                PLANE_CR: begin
                    service_s_valid = cr_s_valid;
                    service_s_data = cr_s_data;
                    cr_s_ready = service_s_ready;
                end
                default: begin end
            endcase
        end
    end

    always_comb begin
        y_m_valid = 1'b0;
        cb_m_valid = 1'b0;
        cr_m_valid = 1'b0;
        service_m_ready = 1'b0;
        y_m_data = service_m_data;
        cb_m_data = service_m_data;
        cr_m_data = service_m_data;
        y_m_x = service_m_x;
        y_m_y = service_m_y;
        cb_m_x = service_m_x[2:0];
        cb_m_y = service_m_y[2:0];
        cr_m_x = service_m_x[2:0];
        cr_m_y = service_m_y[2:0];
        y_m_block_last = service_m_block_last;
        cb_m_block_last = service_m_block_last;
        cr_m_block_last = service_m_block_last;
        if (active) begin
            case (active_plane)
                PLANE_Y: begin
                    y_m_valid = service_m_valid;
                    service_m_ready = y_m_ready;
                end
                PLANE_CB: begin
                    cb_m_valid = service_m_valid;
                    service_m_ready = cb_m_ready;
                end
                PLANE_CR: begin
                    cr_m_valid = service_m_valid;
                    service_m_ready = cr_m_ready;
                end
                default: begin end
            endcase
        end
    end

    assign busy = active;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            active <= 1'b0;
            active_plane <= PLANE_Y;
            input_count <= '0;
            output_count <= '0;
            block_done <= 1'b0;
            completed_plane <= PLANE_Y;
            protocol_error <= 1'b0;
        end else begin
            block_done <= 1'b0;
            if (!active && service_m_valid)
                protocol_error <= 1'b1;
            if (command_fire) begin
                active <= 1'b1;
                active_plane <= selected_plane;
                input_count <= '0;
                output_count <= '0;
            end
            if (input_fire) begin
                if (input_count == expected_input_count)
                    protocol_error <= 1'b1;
                else
                    input_count <= input_count + 1'b1;
            end
            if (output_fire) begin
                if (service_m_block_last) begin
                    if ((output_count != expected_last_index) ||
                        (!input_complete))
                        protocol_error <= 1'b1;
                    active <= 1'b0;
                    block_done <= 1'b1;
                    completed_plane <= active_plane;
                    output_count <= '0;
                end else if (output_count == expected_last_index) begin
                    protocol_error <= 1'b1;
                end else begin
                    output_count <= output_count + 1'b1;
                end
            end
        end
    end

endmodule
