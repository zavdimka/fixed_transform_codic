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

    always_comb begin
        select_base = (owner == BASE) || ((owner == NONE) && base_valid);
        select_lf = (owner == LF)
                 || ((owner == NONE) && !base_valid && lf_valid);
        base_ready = write_ready && select_base;
        lf_ready = write_ready && select_lf;
        write_valid = select_base ? base_valid : select_lf ? lf_valid : 1'b0;
        write_start = select_base ? base_start : lf_start;
        write_last = select_base ? base_last : lf_last;
        write_frame_id = select_base ? base_frame_id : lf_frame_id;
        write_stripe_id = select_base ? base_stripe_id : lf_stripe_id;
        write_plane = select_base ? base_plane : lf_plane;
        write_address = select_base ? base_address : lf_address;
        write_data = select_base ? base_data : lf_data;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            owner <= NONE;
        end else begin
            if ((owner == NONE) && write_valid && write_ready && !write_last)
                owner <= select_base ? BASE : LF;
            else if ((owner != NONE) && write_valid && write_ready && write_last)
                owner <= NONE;
        end
    end
endmodule
