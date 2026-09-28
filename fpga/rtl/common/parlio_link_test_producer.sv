module parlio_link_test_producer (
    input  logic        clk,
    input  logic        rst_n,
    output logic        s_valid,
    input  logic        s_ready,
    output logic [7:0]  s_data,
    output logic        s_layer,
    output logic        s_commit,
    input  logic        s_commit_ready,
    output logic [15:0] frame_id,
    output logic [5:0]  stripe_index,
    output logic [7:0]  quality,
    output logic [16:0] base_bits,
    output logic [16:0] enhancement_bits,
    output logic [15:0] record_index
);
    typedef enum logic {FILL_PAYLOAD, COMMIT_RECORD} state_t;
    state_t state;
    logic [9:0] payload_index;
    logic [9:0] payload_length;

    always_comb begin
        case (record_index[2:0])
            3'd0: payload_length = 10'd1;
            3'd1: payload_length = 10'd7;
            3'd2: payload_length = 10'd31;
            3'd3: payload_length = 10'd127;
            3'd4: payload_length = 10'd257;
            3'd5: payload_length = 10'd511;
            3'd6: payload_length = 10'd899;
            default: payload_length = 10'd900;
        endcase
    end

    assign s_valid = state == FILL_PAYLOAD;
    assign s_commit = state == COMMIT_RECORD;
    assign s_layer = 1'b0;
    assign s_data = 8'ha5 ^ record_index[7:0] ^ payload_index[7:0]
                  ^ {payload_index[3:0], payload_index[7:4]};
    assign frame_id = record_index;
    assign stripe_index = record_index[5:0];
    assign quality = 8'ha5;
    assign base_bits = {4'd0, payload_length, 3'b000};
    assign enhancement_bits = 17'd0;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= FILL_PAYLOAD;
            payload_index <= 10'd0;
            record_index <= 16'd0;
        end else if (state == FILL_PAYLOAD) begin
            if (s_valid && s_ready) begin
                if (payload_index + 1'b1 == payload_length)
                    state <= COMMIT_RECORD;
                else
                    payload_index <= payload_index + 1'b1;
            end
        end else if (s_commit_ready) begin
            record_index <= record_index + 1'b1;
            payload_index <= 10'd0;
            state <= FILL_PAYLOAD;
        end
    end
endmodule
