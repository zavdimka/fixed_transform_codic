module receiver_decoded_write_arbiter2 (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        base_valid,
    output logic        base_ready,
    input  logic        base_start,
    input  logic        base_last,
    input  logic [15:0] base_frame_id,
    input  logic [7:0]  base_stripe_id,
    input  logic [1:0]  base_plane,
    input  logic [14:0] base_address,
    input  logic [7:0]  base_data,

    input  logic        lf_valid,
    output logic        lf_ready,
    input  logic        lf_start,
    input  logic        lf_last,
    input  logic [15:0] lf_frame_id,
    input  logic [7:0]  lf_stripe_id,
    input  logic [1:0]  lf_plane,
    input  logic [14:0] lf_address,
    input  logic [7:0]  lf_data,

    output logic        write_valid,
    input  logic        write_ready,
    output logic        write_start,
    output logic        write_last,
    output logic [15:0] write_frame_id,
    output logic [7:0]  write_stripe_id,
    output logic [1:0]  write_plane,
    output logic [14:0] write_address,
    output logic [7:0]  write_data,
    output logic [1:0]  owner
);
    localparam logic [1:0] NONE = 2'd0;
    localparam logic [1:0] BASE = 2'd1;
    localparam logic [1:0] LF = 2'd2;
    logic select_base, select_lf;
    logic selected_valid, selected_start, selected_last;
    logic [15:0] selected_frame_id;
    logic [7:0] selected_stripe_id;
    logic [1:0] selected_plane;
    logic [14:0] selected_address;
    logic [7:0] selected_data;

    logic fifo_start [0:1];
    logic fifo_last [0:1];
    logic [15:0] fifo_frame_id [0:1];
    logic [7:0] fifo_stripe_id [0:1];
    logic [1:0] fifo_plane [0:1];
    logic [14:0] fifo_address [0:1];
    logic [7:0] fifo_data [0:1];
    logic fifo_write_pointer, fifo_read_pointer;
    logic [1:0] fifo_level;

    wire input_slot_ready = (fifo_level != 2'd2);
    wire selected_fire = input_slot_ready && selected_valid;
    wire output_fire = write_valid && write_ready;

    // Selection stays with one producer until its final sample enters the
    // FIFO. A following transaction may then queue behind that final sample;
    // FIFO order preserves the atomic stripe boundary at the consumer.
    always_comb begin
        select_base = (owner == BASE) || ((owner == NONE) && base_valid);
        select_lf = (owner == LF)
                 || ((owner == NONE) && !base_valid && lf_valid);
        base_ready = input_slot_ready && select_base;
        lf_ready = input_slot_ready && select_lf;
        selected_valid = select_base ? base_valid
                       : select_lf ? lf_valid : 1'b0;
        selected_start = select_base ? base_start : lf_start;
        selected_last = select_base ? base_last : lf_last;
        selected_frame_id = select_base ? base_frame_id : lf_frame_id;
        selected_stripe_id = select_base ? base_stripe_id : lf_stripe_id;
        selected_plane = select_base ? base_plane : lf_plane;
        selected_address = select_base ? base_address : lf_address;
        selected_data = select_base ? base_data : lf_data;

        write_valid = (fifo_level != 0);
        write_start = fifo_start[fifo_read_pointer];
        write_last = fifo_last[fifo_read_pointer];
        write_frame_id = fifo_frame_id[fifo_read_pointer];
        write_stripe_id = fifo_stripe_id[fifo_read_pointer];
        write_plane = fifo_plane[fifo_read_pointer];
        write_address = fifo_address[fifo_read_pointer];
        write_data = fifo_data[fifo_read_pointer];
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            owner <= NONE;
            fifo_write_pointer <= 1'b0;
            fifo_read_pointer <= 1'b0;
            fifo_level <= 2'd0;
            fifo_start[0] <= 1'b0;
            fifo_start[1] <= 1'b0;
            fifo_last[0] <= 1'b0;
            fifo_last[1] <= 1'b0;
            fifo_frame_id[0] <= 16'd0;
            fifo_frame_id[1] <= 16'd0;
            fifo_stripe_id[0] <= 8'd0;
            fifo_stripe_id[1] <= 8'd0;
            fifo_plane[0] <= 2'd0;
            fifo_plane[1] <= 2'd0;
            fifo_address[0] <= 15'd0;
            fifo_address[1] <= 15'd0;
            fifo_data[0] <= 8'd0;
            fifo_data[1] <= 8'd0;
        end else begin
            case ({selected_fire, output_fire})
                2'b10: fifo_level <= fifo_level + 1'b1;
                2'b01: fifo_level <= fifo_level - 1'b1;
                default: begin end
            endcase

            if (selected_fire) begin
                fifo_start[fifo_write_pointer] <= selected_start;
                fifo_last[fifo_write_pointer] <= selected_last;
                fifo_frame_id[fifo_write_pointer] <= selected_frame_id;
                fifo_stripe_id[fifo_write_pointer] <= selected_stripe_id;
                fifo_plane[fifo_write_pointer] <= selected_plane;
                fifo_address[fifo_write_pointer] <= selected_address;
                fifo_data[fifo_write_pointer] <= selected_data;
                fifo_write_pointer <= ~fifo_write_pointer;
            end

            if (output_fire)
                fifo_read_pointer <= ~fifo_read_pointer;

            if ((owner == NONE) && selected_fire && !selected_last)
                owner <= select_base ? BASE : LF;
            else if ((owner != NONE) && selected_fire && selected_last)
                owner <= NONE;
        end
    end
endmodule
