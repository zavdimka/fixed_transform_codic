module receiver_lf_stripe_decoder #(
    parameter integer CTU_COUNT = 80
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        record_valid,
    output logic        record_ready,
    input  logic [15:0] display_frame_id,
    input  logic [7:0]  stripe_id,
    input  logic [7:0]  fragment_index,
    input  logic [7:0]  fragment_count,
    input  logic [7:0]  record_flags,
    input  logic [15:0] payload_length,
    input  logic [7:0]  payload_data,
    input  logic        payload_valid,
    output logic        payload_ready,
    input  logic        payload_last,

    output logic        decoded_write_valid,
    input  logic        decoded_write_ready,
    output logic        decoded_write_start,
    output logic        decoded_write_last,
    output logic [15:0] decoded_frame_id,
    output logic [7:0]  decoded_stripe_id,
    output logic [1:0]  decoded_plane,
    output logic [14:0] decoded_address,
    output logic [7:0]  decoded_data,

    output logic        busy,
    output logic [31:0] completed_stripe_count,
    output logic [31:0] rejected_stripe_count
);
    localparam logic [15:0] LF_BYTES = 16'(CTU_COUNT * 2);
    localparam logic [6:0] LAST_CTU = 7'(CTU_COUNT - 1);
    localparam logic [2:0] IDLE = 3'd0;
    localparam logic [2:0] NEED_Y = 3'd1;
    localparam logic [2:0] EMIT_Y = 3'd2;
    localparam logic [2:0] NEED_C = 3'd3;
    localparam logic [2:0] EMIT_C = 3'd4;
    localparam logic [2:0] DRAIN = 3'd5;

    logic [2:0] state;
    logic [6:0] ctu_index;
    logic [7:0] sample_index;
    logic [7:0] summary_byte;
    logic [14:0] output_address;

    wire metadata_valid = (fragment_index == 0)
                        && (fragment_count == 1)
                        && (record_flags == 0)
                        && (payload_length == LF_BYTES)
                        && (stripe_id < 45);
    wire output_fire = decoded_write_valid && decoded_write_ready;
    wire payload_fire = payload_valid && payload_ready;

    always_comb begin
        record_ready = (state == IDLE);
        payload_ready = (state == NEED_Y) || (state == NEED_C)
                     || (state == DRAIN);
        decoded_write_valid = (state == EMIT_Y) || (state == EMIT_C);
        decoded_write_start = (state == EMIT_Y) && (ctu_index == 0)
                           && (sample_index == 0);
        decoded_write_last = (state == EMIT_C)
                          && (ctu_index == LAST_CTU)
                          && (sample_index == 8'd127);
        decoded_plane = (state == EMIT_Y) ? 2'd0
                      : sample_index[6] ? 2'd2 : 2'd1;
        decoded_address = output_address;
        if (state == EMIT_Y)
            decoded_data = sample_index[3]
                         ? {summary_byte[3:0], summary_byte[3:0]}
                         : {summary_byte[7:4], summary_byte[7:4]};
        else
            decoded_data = sample_index[6]
                         ? {summary_byte[3:0], summary_byte[3:0]}
                         : {summary_byte[7:4], summary_byte[7:4]};
        busy = (state != IDLE);
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            ctu_index <= 7'd0;
            sample_index <= 8'd0;
            summary_byte <= 8'd0;
            output_address <= 15'd0;
            decoded_frame_id <= 16'd0;
            decoded_stripe_id <= 8'd0;
            completed_stripe_count <= 32'd0;
            rejected_stripe_count <= 32'd0;
        end else begin
            if (record_valid && record_ready) begin
                if (metadata_valid) begin
                    decoded_frame_id <= display_frame_id;
                    decoded_stripe_id <= stripe_id;
                    ctu_index <= 7'd0;
                    state <= NEED_Y;
                end else begin
                    rejected_stripe_count <= rejected_stripe_count + 1'b1;
                    state <= (payload_length == 0) ? IDLE : DRAIN;
                end
            end

            if (payload_fire) begin
                if (state == DRAIN) begin
                    if (payload_last)
                        state <= IDLE;
                end else begin
                    summary_byte <= payload_data;
                    sample_index <= 8'd0;
                    if (state == NEED_Y) begin
                        output_address <= {4'd0, ctu_index, 4'd0};
                        state <= EMIT_Y;
                    end else begin
                        output_address <= {5'd0, ctu_index, 3'd0};
                        state <= EMIT_C;
                    end
                end
            end

            if (output_fire) begin
                if (state == EMIT_Y) begin
                    if (sample_index == 8'd255) begin
                        sample_index <= 8'd0;
                        state <= NEED_C;
                    end else begin
                        sample_index <= sample_index + 1'b1;
                        output_address <= (sample_index[3:0] == 4'd15)
                                        ? output_address + 15'd1265
                                        : output_address + 1'b1;
                    end
                end else if (state == EMIT_C) begin
                    if (sample_index == 8'd127) begin
                        sample_index <= 8'd0;
                        if (ctu_index == LAST_CTU) begin
                            completed_stripe_count <=
                                completed_stripe_count + 1'b1;
                            state <= IDLE;
                        end else begin
                            ctu_index <= ctu_index + 1'b1;
                            state <= NEED_Y;
                        end
                    end else begin
                        sample_index <= sample_index + 1'b1;
                        if (sample_index == 8'd63)
                            output_address <= {5'd0, ctu_index, 3'd0};
                        else
                            output_address <= (sample_index[2:0] == 3'd7)
                                            ? output_address + 15'd633
                                            : output_address + 1'b1;
                    end
                end
            end
        end
    end
endmodule
