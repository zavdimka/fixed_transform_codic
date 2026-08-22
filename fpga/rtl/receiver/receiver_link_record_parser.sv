module receiver_link_record_parser (
    input  logic        clk,
    input  logic        rst_n,

    input  logic [9:0]  entry,
    input  logic        entry_valid,
    output logic        entry_ready,

    output logic        record_valid,
    input  logic        record_ready,
    output logic [7:0]  record_type,
    output logic [15:0] record_sequence,
    output logic [15:0] display_frame_id,
    output logic [15:0] source_frame_id,
    output logic [7:0]  stripe_id,
    output logic [7:0]  quality,
    output logic [7:0]  fragment_index,
    output logic [7:0]  fragment_count,
    output logic [7:0]  record_flags,
    output logic [15:0] payload_length,

    output logic [7:0]  payload_data,
    output logic        payload_valid,
    input  logic        payload_ready,
    output logic        payload_last,

    output logic        parser_busy,
    output logic [31:0] accepted_count,
    output logic [31:0] rejected_count,
    output logic [31:0] crc_error_count,
    output logic [31:0] length_error_count,
    output logic [31:0] framing_error_count
);
    localparam logic [1:0] ENTRY_DATA = 2'b00;
    localparam logic [1:0] ENTRY_START_DATA = 2'b01;
    localparam logic [1:0] ENTRY_END = 2'b10;

    localparam logic [2:0] STATE_CAPTURE = 3'd0;
    localparam logic [2:0] STATE_RECORD = 3'd1;
    localparam logic [2:0] STATE_READ_WAIT = 3'd2;
    localparam logic [2:0] STATE_READ_LOAD = 3'd3;
    localparam logic [2:0] STATE_PAYLOAD = 3'd4;

    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    logic [7:0] payload_memory [0:1023];
    logic [2:0] state;
    logic transaction_active;
    logic discard_current;
    logic format_bad;
    logic [10:0] byte_count;
    logic [7:0] payload_length_low;
    logic [15:0] crc_state;
    logic [7:0] received_crc_low, received_crc_high;
    logic [9:0] payload_read_index;
    logic [9:0] memory_read_address;
    logic [7:0] memory_read_data;

    wire [1:0] entry_kind = entry[9:8];
    wire [7:0] entry_data = entry[7:0];
    wire [10:0] payload_end_index =
        11'd18 + {1'b0, payload_length[9:0]};
    wire [10:0] expected_total_bytes = payload_end_index + 11'd2;
    wire payload_memory_write = (state == STATE_CAPTURE)
        && entry_valid && transaction_active
        && (entry_kind == ENTRY_DATA) && !discard_current
        && (byte_count >= 11'd18)
        && (byte_count < payload_end_index);

    // Canonical synchronous RAM ports are intentionally separate from parser
    // control. Efinity otherwise expands the variable replay mux into flops.
    always_ff @(posedge clk) begin
        if (payload_memory_write)
            payload_memory[byte_count[9:0] - 10'd18] <= entry_data;
        memory_read_data <= payload_memory[memory_read_address];
    end

    function automatic [15:0] crc16_ccitt_byte(
        input [15:0] crc_in,
        input [7:0] data_in
    );
        integer crc_bit;
        reg [15:0] crc_work;
        begin
            crc_work = crc_in ^ {data_in, 8'd0};
            for (crc_bit = 0; crc_bit < 8; crc_bit = crc_bit + 1) begin
                if (crc_work[15])
                    crc_work = (crc_work << 1) ^ 16'h1021;
                else
                    crc_work = crc_work << 1;
            end
            crc16_ccitt_byte = crc_work;
        end
    endfunction

    function automatic logic supported_record_type(input [7:0] value);
        begin
            case (value)
                8'h01, // display-frame start
                8'h02, // display-frame end
                8'h10, // stripe base
                8'h11, // stripe enhancement
                8'h12, // LF-only recovered stripe
                8'h13, // explicit missing stripe
                8'h7F: supported_record_type = 1'b1; // control/resync
                default: supported_record_type = 1'b0;
            endcase
        end
    endfunction

    assign entry_ready = (state == STATE_CAPTURE);
    assign parser_busy = transaction_active || (state != STATE_CAPTURE);

    task automatic start_transaction(input [7:0] first_byte);
        begin
            transaction_active <= 1'b1;
            discard_current <= 1'b0;
            format_bad <= (first_byte != 8'hC5);
            byte_count <= 11'd1;
            crc_state <= crc16_ccitt_byte(16'hFFFF, first_byte);
            received_crc_low <= 8'd0;
            received_crc_high <= 8'd0;
            payload_length_low <= 8'd0;
            payload_length <= 16'd0;
        end
    endtask

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= STATE_CAPTURE;
            transaction_active <= 1'b0;
            discard_current <= 1'b0;
            format_bad <= 1'b0;
            byte_count <= 11'd0;
            payload_length_low <= 8'd0;
            crc_state <= 16'hFFFF;
            received_crc_low <= 8'd0;
            received_crc_high <= 8'd0;
            record_valid <= 1'b0;
            record_type <= 8'd0;
            record_sequence <= 16'd0;
            display_frame_id <= 16'd0;
            source_frame_id <= 16'd0;
            stripe_id <= 8'd0;
            quality <= 8'd0;
            fragment_index <= 8'd0;
            fragment_count <= 8'd0;
            record_flags <= 8'd0;
            payload_length <= 16'd0;
            payload_data <= 8'd0;
            payload_valid <= 1'b0;
            payload_last <= 1'b0;
            payload_read_index <= 10'd0;
            memory_read_address <= 10'd0;
            accepted_count <= 32'd0;
            rejected_count <= 32'd0;
            crc_error_count <= 32'd0;
            length_error_count <= 32'd0;
            framing_error_count <= 32'd0;
        end else begin
            case (state)
                STATE_CAPTURE: begin
                    payload_valid <= 1'b0;
                    record_valid <= 1'b0;
                    if (entry_valid) begin
                        case (entry_kind)
                            ENTRY_START_DATA: begin
                                if (transaction_active) begin
                                    rejected_count <= rejected_count + 1'b1;
                                    framing_error_count <=
                                        framing_error_count + 1'b1;
                                end
                                start_transaction(entry_data);
                            end
                            ENTRY_DATA: begin
                                if (!transaction_active) begin
                                    framing_error_count <=
                                        framing_error_count + 1'b1;
                                end else if (byte_count
                                             >= 11'd1024) begin
                                    discard_current <= 1'b1;
                                end else if (discard_current) begin
                                    byte_count <= byte_count + 1'b1;
                                end else begin
                                    byte_count <= byte_count + 1'b1;
                                    case (byte_count)
                                        11'd1: begin
                                            if (entry_data != 8'h3A)
                                                format_bad <= 1'b1;
                                            crc_state <= crc16_ccitt_byte(
                                                crc_state, entry_data
                                            );
                                        end
                                        11'd2: begin
                                            if (entry_data != 8'h01)
                                                format_bad <= 1'b1;
                                            crc_state <= crc16_ccitt_byte(
                                                crc_state, entry_data
                                            );
                                        end
                                        11'd3: begin
                                            record_type <= entry_data;
                                            if (!supported_record_type(entry_data))
                                                format_bad <= 1'b1;
                                            crc_state <= crc16_ccitt_byte(
                                                crc_state, entry_data
                                            );
                                        end
                                        11'd4: begin
                                            record_sequence[7:0] <= entry_data;
                                            crc_state <= crc16_ccitt_byte(
                                                crc_state, entry_data
                                            );
                                        end
                                        11'd5: begin
                                            record_sequence[15:8] <= entry_data;
                                            crc_state <= crc16_ccitt_byte(
                                                crc_state, entry_data
                                            );
                                        end
                                        11'd6: begin
                                            display_frame_id[7:0] <= entry_data;
                                            crc_state <= crc16_ccitt_byte(
                                                crc_state, entry_data
                                            );
                                        end
                                        11'd7: begin
                                            display_frame_id[15:8] <= entry_data;
                                            crc_state <= crc16_ccitt_byte(
                                                crc_state, entry_data
                                            );
                                        end
                                        11'd8: begin
                                            source_frame_id[7:0] <= entry_data;
                                            crc_state <= crc16_ccitt_byte(
                                                crc_state, entry_data
                                            );
                                        end
                                        11'd9: begin
                                            source_frame_id[15:8] <= entry_data;
                                            crc_state <= crc16_ccitt_byte(
                                                crc_state, entry_data
                                            );
                                        end
                                        11'd10: begin
                                            stripe_id <= entry_data;
                                            crc_state <= crc16_ccitt_byte(
                                                crc_state, entry_data
                                            );
                                        end
                                        11'd11: begin
                                            quality <= entry_data;
                                            crc_state <= crc16_ccitt_byte(
                                                crc_state, entry_data
                                            );
                                        end
                                        11'd12: begin
                                            fragment_index <= entry_data;
                                            crc_state <= crc16_ccitt_byte(
                                                crc_state, entry_data
                                            );
                                        end
                                        11'd13: begin
                                            fragment_count <= entry_data;
                                            if ((entry_data == 0)
                                                || (fragment_index >= entry_data))
                                                format_bad <= 1'b1;
                                            crc_state <= crc16_ccitt_byte(
                                                crc_state, entry_data
                                            );
                                        end
                                        11'd14: begin
                                            record_flags <= entry_data;
                                            crc_state <= crc16_ccitt_byte(
                                                crc_state, entry_data
                                            );
                                        end
                                        11'd15: begin
                                            if (entry_data != 0)
                                                format_bad <= 1'b1;
                                            crc_state <= crc16_ccitt_byte(
                                                crc_state, entry_data
                                            );
                                        end
                                        11'd16: begin
                                            payload_length_low <= entry_data;
                                            crc_state <= crc16_ccitt_byte(
                                                crc_state, entry_data
                                            );
                                        end
                                        11'd17: begin
                                            payload_length <= {
                                                entry_data,
                                                payload_length_low
                                            };
                                            if ({entry_data,
                                                 payload_length_low}
                                                > 16'd1004)
                                                discard_current <= 1'b1;
                                            crc_state <= crc16_ccitt_byte(
                                                crc_state, entry_data
                                            );
                                        end
                                        default: begin
                                            if (byte_count
                                                < payload_end_index) begin
                                                crc_state <= crc16_ccitt_byte(
                                                    crc_state, entry_data
                                                );
                                            end else if (byte_count
                                                == payload_end_index) begin
                                                received_crc_low <= entry_data;
                                            end else if (byte_count
                                                == (payload_end_index + 1'b1)) begin
                                                received_crc_high <= entry_data;
                                            end else begin
                                                discard_current <= 1'b1;
                                            end
                                        end
                                    endcase
                                end
                            end
                            ENTRY_END: begin
                                if (!transaction_active) begin
                                    framing_error_count <=
                                        framing_error_count + 1'b1;
                                end else begin
                                    transaction_active <= 1'b0;
                                    if (discard_current
                                        || (byte_count < 11'd20)
                                        || (byte_count
                                            != expected_total_bytes)) begin
                                        rejected_count <= rejected_count + 1'b1;
                                        length_error_count <=
                                            length_error_count + 1'b1;
                                    end else if (format_bad) begin
                                        rejected_count <= rejected_count + 1'b1;
                                        framing_error_count <=
                                            framing_error_count + 1'b1;
                                    end else if (crc_state
                                                 != {received_crc_high,
                                                     received_crc_low}) begin
                                        rejected_count <= rejected_count + 1'b1;
                                        crc_error_count <=
                                            crc_error_count + 1'b1;
                                    end else begin
                                        accepted_count <= accepted_count + 1'b1;
                                        record_valid <= 1'b1;
                                        state <= STATE_RECORD;
                                    end
                                end
                            end
                            default: begin
                                discard_current <= 1'b1;
                                framing_error_count <=
                                    framing_error_count + 1'b1;
                            end
                        endcase
                    end
                end
                STATE_RECORD: begin
                    if (record_valid && record_ready) begin
                        record_valid <= 1'b0;
                        if (payload_length == 0) begin
                            state <= STATE_CAPTURE;
                        end else begin
                            payload_read_index <= 10'd0;
                            memory_read_address <= 10'd0;
                            state <= STATE_READ_WAIT;
                        end
                    end
                end
                STATE_READ_WAIT: begin
                    state <= STATE_READ_LOAD;
                end
                STATE_READ_LOAD: begin
                    payload_data <= memory_read_data;
                    payload_valid <= 1'b1;
                    payload_last <= (payload_read_index + 1'b1
                                     == payload_length[9:0]);
                    state <= STATE_PAYLOAD;
                end
                STATE_PAYLOAD: begin
                    if (payload_valid && payload_ready) begin
                        if (payload_last) begin
                            payload_valid <= 1'b0;
                            payload_last <= 1'b0;
                            state <= STATE_CAPTURE;
                        end else begin
                            payload_read_index <= payload_read_index + 1'b1;
                            memory_read_address <= payload_read_index + 1'b1;
                            payload_valid <= 1'b0;
                            state <= STATE_READ_WAIT;
                        end
                    end
                end
                default: state <= STATE_CAPTURE;
            endcase
        end
    end
endmodule
