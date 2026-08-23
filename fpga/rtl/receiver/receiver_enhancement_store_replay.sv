module receiver_enhancement_store_replay #(
    parameter integer MAX_BYTES = 1536
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        record_valid,
    output logic        record_ready,
    input  logic [15:0] display_frame_id,
    input  logic [7:0]  stripe_id,
    input  logic [7:0]  quality,
    input  logic [7:0]  fragment_index,
    input  logic [7:0]  fragment_count,
    input  logic [7:0]  record_flags,
    input  logic [15:0] payload_length,
    input  logic [7:0]  payload_data,
    input  logic        payload_valid,
    output logic        payload_ready,
    input  logic        payload_last,

    input  logic        request_valid,
    input  logic [15:0] request_frame_id,
    input  logic [7:0]  request_stripe_id,
    output logic        request_ready,

    output logic        replay_record_valid,
    input  logic        replay_record_ready,
    output logic [15:0] replay_frame_id,
    output logic [7:0]  replay_stripe_id,
    output logic [7:0]  replay_quality,
    output logic [7:0]  replay_record_flags,
    output logic [15:0] replay_payload_length,
    output logic [7:0]  replay_payload_data,
    output logic        replay_payload_valid,
    input  logic        replay_payload_ready,
    output logic        replay_payload_last,

    output logic        stored_valid,
    output logic [15:0] stored_frame_id,
    output logic [7:0]  stored_stripe_id,
    output logic [31:0] stored_count,
    output logic [31:0] rejected_count,
    output logic [31:0] replayed_count,
    output logic [31:0] request_miss_count
);
    localparam logic [2:0] R_IDLE    = 3'd0;
    localparam logic [2:0] R_HEADER  = 3'd1;
    localparam logic [2:0] R_ISSUE   = 3'd2;
    localparam logic [2:0] R_WAIT    = 3'd3;
    localparam logic [2:0] R_PRESENT = 3'd4;
    localparam logic [15:0] MAX_BYTES_VALUE = 16'(MAX_BYTES);

    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    logic [7:0] store0 [0:511];
    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    logic [7:0] store1 [0:511];
    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    logic [7:0] store2 [0:511];

    logic assembly_active, payload_active, capture_accept;
    logic [15:0] capture_frame_id;
    logic [7:0] capture_stripe_id, capture_quality;
    logic [7:0] capture_fragment_count, expected_fragment_index;
    logic [15:0] capture_length, fragment_bytes_seen;
    logic [15:0] current_payload_length;
    logic [7:0] current_record_flags;
    logic current_last_fragment;
    logic [2:0] replay_state;
    logic [15:0] replay_address;
    logic [7:0] synchronous_read_data;

    wire replay_busy = (replay_state != R_IDLE);
    wire payload_fire = payload_valid && payload_ready;
    wire request_match = stored_valid
                       && (request_frame_id == stored_frame_id)
                       && (request_stripe_id == stored_stripe_id);
    wire [15:0] next_capture_length = capture_length + 1'b1;
    wire [16:0] aggregate_length = {1'b0, capture_length}
                                 + {1'b0, payload_length};

    assign record_ready = !replay_busy;
    assign payload_ready = payload_active && !replay_busy;
    assign request_ready = !replay_busy && !assembly_active
                         && !payload_active;

    always_ff @(posedge clk) begin
        if (payload_fire && capture_accept
            && (capture_length < MAX_BYTES_VALUE)) begin
            case (capture_length[10:9])
                2'd0: store0[capture_length[8:0]] <= payload_data;
                2'd1: store1[capture_length[8:0]] <= payload_data;
                default: store2[capture_length[8:0]] <= payload_data;
            endcase
        end

        if (replay_state == R_ISSUE) begin
            case (replay_address[10:9])
                2'd0: synchronous_read_data <= store0[replay_address[8:0]];
                2'd1: synchronous_read_data <= store1[replay_address[8:0]];
                default: synchronous_read_data <= store2[replay_address[8:0]];
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            assembly_active <= 1'b0;
            payload_active <= 1'b0;
            capture_accept <= 1'b0;
            capture_frame_id <= 16'd0;
            capture_stripe_id <= 8'd0;
            capture_quality <= 8'd0;
            capture_fragment_count <= 8'd0;
            expected_fragment_index <= 8'd0;
            capture_length <= 16'd0;
            fragment_bytes_seen <= 16'd0;
            current_payload_length <= 16'd0;
            current_record_flags <= 8'd0;
            current_last_fragment <= 1'b0;
            replay_state <= R_IDLE;
            replay_address <= 16'd0;
            replay_record_valid <= 1'b0;
            replay_frame_id <= 16'd0;
            replay_stripe_id <= 8'd0;
            replay_quality <= 8'd0;
            replay_record_flags <= 8'd0;
            replay_payload_length <= 16'd0;
            replay_payload_data <= 8'd0;
            replay_payload_valid <= 1'b0;
            replay_payload_last <= 1'b0;
            stored_valid <= 1'b0;
            stored_frame_id <= 16'd0;
            stored_stripe_id <= 8'd0;
            stored_count <= 32'd0;
            rejected_count <= 32'd0;
            replayed_count <= 32'd0;
            request_miss_count <= 32'd0;
        end else begin
            if (record_valid && record_ready) begin
                fragment_bytes_seen <= 16'd0;
                current_payload_length <= payload_length;
                current_record_flags <= record_flags;
                current_last_fragment <=
                    (fragment_index + 1'b1 == fragment_count);
                payload_active <= (payload_length != 0);
                if (payload_length == 0) begin
                    capture_accept <= 1'b0;
                    assembly_active <= 1'b0;
                    rejected_count <= rejected_count + 1'b1;
                end else if (fragment_index == 0) begin
                    assembly_active <= 1'b1;
                    capture_accept <= (fragment_count != 0)
                                   && (payload_length <= MAX_BYTES_VALUE);
                    capture_frame_id <= display_frame_id;
                    capture_stripe_id <= stripe_id;
                    capture_quality <= quality;
                    capture_fragment_count <= fragment_count;
                    expected_fragment_index <= 8'd1;
                    capture_length <= 16'd0;
                    stored_valid <= 1'b0;
                    if ((fragment_count == 0)
                        || (payload_length > MAX_BYTES_VALUE))
                        rejected_count <= rejected_count + 1'b1;
                end else if (assembly_active
                             && capture_accept
                             && (display_frame_id == capture_frame_id)
                             && (stripe_id == capture_stripe_id)
                             && (quality == capture_quality)
                             && (fragment_count == capture_fragment_count)
                             && (fragment_index
                                 == expected_fragment_index)
                             && (aggregate_length
                                 <= {1'b0, MAX_BYTES_VALUE})) begin
                    expected_fragment_index <=
                        expected_fragment_index + 1'b1;
                end else begin
                    capture_accept <= 1'b0;
                    assembly_active <= 1'b0;
                    stored_valid <= 1'b0;
                    rejected_count <= rejected_count + 1'b1;
                end
            end

            if (payload_fire) begin
                fragment_bytes_seen <= fragment_bytes_seen + 1'b1;
                if (capture_accept
                    && (capture_length < MAX_BYTES_VALUE))
                    capture_length <= next_capture_length;

                if (payload_last) begin
                    payload_active <= 1'b0;
                    if (capture_accept
                        && (fragment_bytes_seen + 1'b1
                            == current_payload_length)) begin
                        if (current_last_fragment) begin
                            assembly_active <= 1'b0;
                            stored_valid <= 1'b1;
                            stored_frame_id <= capture_frame_id;
                            stored_stripe_id <= capture_stripe_id;
                            replay_frame_id <= capture_frame_id;
                            replay_stripe_id <= capture_stripe_id;
                            replay_quality <= capture_quality;
                            replay_record_flags <= current_record_flags;
                            replay_payload_length <= next_capture_length;
                            stored_count <= stored_count + 1'b1;
                        end
                    end else if (capture_accept) begin
                        assembly_active <= 1'b0;
                        stored_valid <= 1'b0;
                        rejected_count <= rejected_count + 1'b1;
                    end
                end
            end

            if (request_valid && request_ready) begin
                if (request_match) begin
                    replay_state <= R_HEADER;
                    replay_record_valid <= 1'b1;
                    replay_address <= 16'd0;
                    replay_payload_valid <= 1'b0;
                end else begin
                    request_miss_count <= request_miss_count + 1'b1;
                end
            end

            case (replay_state)
                R_HEADER: if (replay_record_valid
                              && replay_record_ready) begin
                    replay_record_valid <= 1'b0;
                    replay_state <= R_ISSUE;
                end
                R_ISSUE: replay_state <= R_WAIT;
                R_WAIT: begin
                    replay_payload_data <= synchronous_read_data;
                    replay_payload_last <=
                        (replay_address + 1'b1 == replay_payload_length);
                    replay_payload_valid <= 1'b1;
                    replay_state <= R_PRESENT;
                end
                R_PRESENT: if (replay_payload_valid
                              && replay_payload_ready) begin
                    replay_payload_valid <= 1'b0;
                    if (replay_payload_last) begin
                        replay_state <= R_IDLE;
                        stored_valid <= 1'b0;
                        replayed_count <= replayed_count + 1'b1;
                    end else begin
                        replay_address <= replay_address + 1'b1;
                        replay_state <= R_ISSUE;
                    end
                end
                default: begin end
            endcase
        end
    end
endmodule
