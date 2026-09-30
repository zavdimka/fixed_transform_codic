module receiver_sparse_base_idct8_dual (
    input logic clk, rst_n,
    input logic command_valid,
    output logic command_ready,
    input logic [6:0] command_ctu_index,
    input logic [2:0] command_block_index,
    input logic [1:0] command_plane, command_mode,
    input logic [7:0] command_quality,
    input logic [71:0] command_coefficients,
    output logic pixel_valid,
    input logic pixel_ready,
    output logic [5:0] pixel_index,
    output logic signed [15:0] pixel_residual,
    output logic pixel_last,
    output logic [6:0] pixel_ctu_index,
    output logic [2:0] pixel_block_index,
    output logic [1:0] pixel_plane, pixel_mode,
    output logic done, busy, saturated
);
    // One core needs 24 clocks to pixel zero. Starting the alternate core at
    // pixel 40 hides that preparation behind the 23 remaining output clocks.
    localparam logic [5:0] PRELAUNCH_PIXEL = 6'd40;

    logic owner, owner_valid, preferred;
    logic c0_ready, c1_ready, v0, v1, r0, r1, last0, last1;
    logic [5:0] index0, index1;
    logic signed [15:0] residual0, residual1;
    logic [6:0] ctu0, ctu1;
    logic [2:0] block0, block1;
    logic [1:0] plane0, plane1, mode0, mode1;
    logic done0, done1, busy0, busy1, saturated0, saturated1;

    wire active_valid = owner ? v1 : v0;
    wire [5:0] active_index = owner ? index1 : index0;
    wire active_last = owner ? last1 : last0;
    wire active_fire = owner_valid && active_valid && pixel_ready;
    wire launch_window = owner_valid && active_valid
                       && (active_index >= PRELAUNCH_PIXEL);
    wire selected = owner_valid ? !owner : preferred;
    wire selected_ready = selected ? c1_ready : c0_ready;
    assign command_ready = owner_valid
                         ? (launch_window && selected_ready)
                         : selected_ready;
    wire command_fire = command_valid && command_ready;
    wire command0 = command_fire && !selected;
    wire command1 = command_fire && selected;

    assign r0 = owner_valid && !owner && pixel_ready;
    assign r1 = owner_valid && owner && pixel_ready;

    always_comb begin
        pixel_valid = 1'b0;
        pixel_index = 6'd0;
        pixel_residual = 16'sd0;
        pixel_last = 1'b0;
        pixel_ctu_index = 7'd0;
        pixel_block_index = 3'd0;
        pixel_plane = 2'd0;
        pixel_mode = 2'd0;
        if (owner_valid) begin
            if (owner) begin
                pixel_valid = v1;
                pixel_index = index1;
                pixel_residual = residual1;
                pixel_last = last1;
                pixel_ctu_index = ctu1;
                pixel_block_index = block1;
                pixel_plane = plane1;
                pixel_mode = mode1;
            end else begin
                pixel_valid = v0;
                pixel_index = index0;
                pixel_residual = residual0;
                pixel_last = last0;
                pixel_ctu_index = ctu0;
                pixel_block_index = block0;
                pixel_plane = plane0;
                pixel_mode = mode0;
            end
        end
    end

    assign done = done0 || done1;
    assign busy = busy0 || busy1;
    assign saturated = saturated0 || saturated1;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            owner <= 1'b0;
            owner_valid <= 1'b0;
            preferred <= 1'b0;
        end else begin
            if (!owner_valid && command_fire) begin
                owner <= selected;
                owner_valid <= 1'b1;
                preferred <= !selected;
            end
            if (active_fire && active_last) begin
                // command_fire covers a launch on this same final-pixel edge.
                if ((owner ? busy0 : busy1) || command_fire) begin
                    owner <= !owner;
                    owner_valid <= 1'b1;
                    preferred <= owner;
                end else begin
                    owner_valid <= 1'b0;
                    preferred <= !owner;
                end
            end
        end
    end

    receiver_sparse_base_idct8 core0 (
        .clk(clk), .rst_n(rst_n), .command_valid(command0),
        .command_ready(c0_ready), .command_ctu_index(command_ctu_index),
        .command_block_index(command_block_index),
        .command_plane(command_plane), .command_mode(command_mode),
        .command_quality(command_quality),
        .command_coefficients(command_coefficients),
        .pixel_valid(v0), .pixel_ready(r0), .pixel_index(index0),
        .pixel_residual(residual0), .pixel_last(last0),
        .pixel_ctu_index(ctu0), .pixel_block_index(block0),
        .pixel_plane(plane0), .pixel_mode(mode0),
        .done(done0), .busy(busy0), .saturated(saturated0)
    );
    receiver_sparse_base_idct8 core1 (
        .clk(clk), .rst_n(rst_n), .command_valid(command1),
        .command_ready(c1_ready), .command_ctu_index(command_ctu_index),
        .command_block_index(command_block_index),
        .command_plane(command_plane), .command_mode(command_mode),
        .command_quality(command_quality),
        .command_coefficients(command_coefficients),
        .pixel_valid(v1), .pixel_ready(r1), .pixel_index(index1),
        .pixel_residual(residual1), .pixel_last(last1),
        .pixel_ctu_index(ctu1), .pixel_block_index(block1),
        .pixel_plane(plane1), .pixel_mode(mode1),
        .done(done1), .busy(busy1), .saturated(saturated1)
    );
endmodule
