module hevc_coefficient_pingpong16 (
    input  logic               clk,
    input  logic               rst_n,

    input  logic               s_valid,
    output logic               s_ready,
    input  logic [7:0]         s_raster_address,
    input  logic signed [15:0] s_coefficient,
    input  logic               s_block_last,

    output logic               block_valid,
    input  logic               block_ready,
    output logic               block_bank,
    output logic               block_any_nonzero,
    output logic [7:0]         block_last_nonzero_scan_position,
    output logic [15:0]        block_significant_group_flags,
    output logic               block_input_error,

    input  logic               read_enable,
    input  logic [7:0]         read_address,
    output logic signed [15:0] read_data,
    output logic               read_active,

    input  logic               release_valid,
    output logic               release_ready
);
    logic [1:0] bank_in_use;
    logic load_active;
    logic load_bank;
    logic [7:0] load_count;

    logic bank_any_nonzero [0:1];
    logic [7:0] bank_last_position [0:1];
    logic [15:0] bank_group_flags [0:1];
    logic bank_error [0:1];

    logic [1:0] queue_count;
    logic queue_write_pointer;
    logic queue_read_pointer;
    logic queue_bank [0:1];

    logic active_bank;
    logic signed [15:0] bank0_read_data;
    logic signed [15:0] bank1_read_data;

    logic selected_load_bank;
    logic write_fire;
    logic write_nonzero;
    logic write_completes;
    logic enqueue;
    logic dequeue;

    function automatic logic [3:0] inverse_diagonal4(
        input logic [3:0] raster
    );
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

    always_comb begin
        if (load_active) begin
            selected_load_bank = load_bank;
        end else begin
            selected_load_bank = bank_in_use[0] ? 1'b1 : 1'b0;
        end
    end

    assign s_ready = load_active || (bank_in_use != 2'b11);
    assign write_fire = s_valid && s_ready;
    assign write_nonzero = (s_coefficient != 0);
    assign write_completes =
        write_fire && (s_block_last || (load_count == 8'hff));
    assign enqueue = write_completes;
    assign dequeue = block_valid && block_ready;

    assign block_valid = (queue_count != 0) && !read_active;
    assign block_bank = queue_bank[queue_read_pointer];
    assign block_any_nonzero =
        bank_any_nonzero[queue_bank[queue_read_pointer]];
    assign block_last_nonzero_scan_position =
        bank_last_position[queue_bank[queue_read_pointer]];
    assign block_significant_group_flags =
        bank_group_flags[queue_bank[queue_read_pointer]];
    assign block_input_error =
        bank_error[queue_bank[queue_read_pointer]];

    assign release_ready = read_active;
    assign read_data = active_bank ? bank1_read_data : bank0_read_data;

    hevc_coefficient_buffer16 bank0 (
        .clk(clk),
        .write_enable(write_fire && !selected_load_bank),
        .write_address(s_raster_address),
        .write_data(s_coefficient),
        .read_enable(read_enable && read_active && !active_bank),
        .read_address(read_address),
        .read_data(bank0_read_data)
    );

    hevc_coefficient_buffer16 bank1 (
        .clk(clk),
        .write_enable(write_fire && selected_load_bank),
        .write_address(s_raster_address),
        .write_data(s_coefficient),
        .read_enable(read_enable && read_active && active_bank),
        .read_address(read_address),
        .read_data(bank1_read_data)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            bank_in_use <= 2'b00;
            load_active <= 1'b0;
            load_bank <= 1'b0;
            load_count <= 8'd0;
            bank_any_nonzero[0] <= 1'b0;
            bank_any_nonzero[1] <= 1'b0;
            bank_last_position[0] <= 8'd0;
            bank_last_position[1] <= 8'd0;
            bank_group_flags[0] <= 16'd0;
            bank_group_flags[1] <= 16'd0;
            bank_error[0] <= 1'b0;
            bank_error[1] <= 1'b0;
            queue_count <= 2'd0;
            queue_write_pointer <= 1'b0;
            queue_read_pointer <= 1'b0;
            queue_bank[0] <= 1'b0;
            queue_bank[1] <= 1'b0;
            active_bank <= 1'b0;
            read_active <= 1'b0;
        end else begin
            case ({enqueue, dequeue})
                2'b10: queue_count <= queue_count + 1'b1;
                2'b01: queue_count <= queue_count - 1'b1;
                default: queue_count <= queue_count;
            endcase

            if (enqueue) begin
                queue_bank[queue_write_pointer] <= selected_load_bank;
                queue_write_pointer <= !queue_write_pointer;
            end
            if (dequeue) begin
                active_bank <= queue_bank[queue_read_pointer];
                queue_read_pointer <= !queue_read_pointer;
                read_active <= 1'b1;
            end
            if (release_valid && release_ready) begin
                bank_in_use[active_bank] <= 1'b0;
                read_active <= 1'b0;
            end

            if (write_fire) begin
                if (!load_active) begin
                    bank_in_use[selected_load_bank] <= 1'b1;
                    load_bank <= selected_load_bank;
                    bank_any_nonzero[selected_load_bank] <= write_nonzero;
                    bank_last_position[selected_load_bank] <=
                        write_nonzero ? write_scan_position : 8'd0;
                    bank_group_flags[selected_load_bank] <=
                        write_nonzero ?
                        (16'd1 << write_group_raster) : 16'd0;
                    bank_error[selected_load_bank] <=
                        s_block_last != (load_count == 8'hff);
                end else begin
                    if (write_nonzero) begin
                        bank_any_nonzero[selected_load_bank] <= 1'b1;
                        bank_group_flags[selected_load_bank][
                            write_group_raster
                        ] <= 1'b1;
                        if (!bank_any_nonzero[selected_load_bank] ||
                                write_scan_position >
                                bank_last_position[selected_load_bank]) begin
                            bank_last_position[selected_load_bank] <=
                                write_scan_position;
                        end
                    end
                    if (write_completes &&
                            s_block_last != (load_count == 8'hff)) begin
                        bank_error[selected_load_bank] <= 1'b1;
                    end
                end

                if (write_completes) begin
                    load_active <= 1'b0;
                    load_count <= 8'd0;
                end else begin
                    load_active <= 1'b1;
                    load_count <= load_count + 1'b1;
                end
            end
        end
    end
endmodule
