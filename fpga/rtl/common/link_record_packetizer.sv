module link_record_packetizer #(
    parameter integer MAX_LAYER_BYTES = 2048,
    parameter integer FRAGMENT_BYTES = 900,
    parameter integer WIRE_RECORD_BYTES = 0,
    parameter integer ADDRESS_WIDTH = $clog2(MAX_LAYER_BYTES)
) (
    input  logic                     write_clk,
    input  logic                     write_rst_n,
    input  logic                     s_valid,
    output logic                     s_ready,
    input  logic [7:0]               s_data,
    input  logic                     s_layer,
    input  logic                     s_commit,
    output logic                     s_commit_ready,
    input  logic [15:0]              s_frame_id,
    input  logic [5:0]               s_stripe_index,
    input  logic [7:0]               s_quality,
    input  logic [16:0]              s_base_bits,
    input  logic [16:0]              s_enhancement_bits,
    output logic                     write_overflow,

    input  logic                     read_clk,
    input  logic                     read_rst_n,
    input  logic                     read_enable,
    input  logic [15:0]              gap_cycles,
    output logic                     packet_active,
    output logic [3:0]               packet_data,
    output logic                     packet_layer,
    output logic                     packet_start,
    output logic                     packet_end,
    output logic [15:0]              packet_byte_length,
    output logic [31:0]              packet_count
);
    localparam integer LENGTH_WIDTH = ADDRESS_WIDTH + 1;
    localparam integer MEMORY_ADDRESS_WIDTH = ADDRESS_WIDTH + 2;
    localparam logic [LENGTH_WIDTH-1:0] MAX_LENGTH =
        LENGTH_WIDTH'(MAX_LAYER_BYTES);

    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    logic [7:0] packet_memory [0:MAX_LAYER_BYTES*4-1];

    logic write_bank;
    logic [LENGTH_WIDTH-1:0] write_length [0:1];
    logic [LENGTH_WIDTH-1:0] committed_length [0:1][0:1];
    logic [15:0] committed_frame_id [0:1];
    logic [5:0] committed_stripe_index [0:1];
    logic [7:0] committed_quality [0:1];
    logic [16:0] committed_bits [0:1][0:1];
    logic [1:0] commit_toggle;
    logic [1:0] done_toggle;
    (* async_reg = "true" *) logic [1:0] done_write_sync_1;
    (* async_reg = "true" *) logic [1:0] done_write_sync_2;
    (* async_reg = "true" *) logic [1:0] commit_read_sync_1;
    (* async_reg = "true" *) logic [1:0] commit_read_sync_2;

    wire write_bank_available =
        done_write_sync_2[write_bank] == commit_toggle[write_bank];
    wire [LENGTH_WIDTH-1:0] selected_write_length =
        write_length[s_layer];
    assign s_ready = write_bank_available;
    assign s_commit_ready = write_bank_available;

    always_ff @(posedge write_clk) begin
        if (!write_rst_n) begin
            write_bank <= 1'b0;
            write_length[0] <= '0;
            write_length[1] <= '0;
            committed_length[0][0] <= '0;
            committed_length[0][1] <= '0;
            committed_length[1][0] <= '0;
            committed_length[1][1] <= '0;
            committed_frame_id[0] <= '0;
            committed_frame_id[1] <= '0;
            committed_stripe_index[0] <= '0;
            committed_stripe_index[1] <= '0;
            committed_quality[0] <= 8'd24;
            committed_quality[1] <= 8'd24;
            committed_bits[0][0] <= '0;
            committed_bits[0][1] <= '0;
            committed_bits[1][0] <= '0;
            committed_bits[1][1] <= '0;
            commit_toggle <= 2'b00;
            done_write_sync_1 <= 2'b00;
            done_write_sync_2 <= 2'b00;
            write_overflow <= 1'b0;
        end else begin
            done_write_sync_1 <= done_toggle;
            done_write_sync_2 <= done_write_sync_1;
            if (s_valid && s_ready) begin
                if (selected_write_length < MAX_LENGTH) begin
                    packet_memory[{write_bank, s_layer,
                        selected_write_length[ADDRESS_WIDTH-1:0]}] <= s_data;
                    write_length[s_layer] <= selected_write_length + 1'b1;
                end else begin
                    write_overflow <= 1'b1;
                end
            end
            if (s_commit && s_commit_ready) begin
                committed_length[write_bank][0] <= write_length[0];
                committed_length[write_bank][1] <= write_length[1];
                committed_frame_id[write_bank] <= s_frame_id;
                committed_stripe_index[write_bank] <= s_stripe_index;
                committed_quality[write_bank] <= s_quality;
                committed_bits[write_bank][0] <= s_base_bits;
                committed_bits[write_bank][1] <= s_enhancement_bits;
                commit_toggle[write_bank] <= ~commit_toggle[write_bank];
                write_bank <= ~write_bank;
                write_length[0] <= '0;
                write_length[1] <= '0;
            end
        end
    end

    function automatic logic [15:0] crc16_byte(
        input logic [15:0] crc_in,
        input logic [7:0] data_in
    );
        logic [15:0] value;
        integer bit_index;
        begin
            value = crc_in ^ {data_in, 8'd0};
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1)
                value = value[15] ? (value << 1) ^ 16'h1021
                                  : (value << 1);
            crc16_byte = value;
        end
    endfunction

    typedef enum logic [3:0] {
        READ_IDLE, PREP_RECORD, HEADER_HIGH, HEADER_LOW,
        PAYLOAD_HIGH, PAYLOAD_LOW, CRC_LOW_HIGH, CRC_LOW_LOW,
        CRC_HIGH_HIGH, CRC_HIGH_LOW, PAD_HIGH, PAD_LOW,
        FINISH_RECORD, READ_GAP
    } read_state_t;
    read_state_t read_state;
    logic read_bank;
    logic [LENGTH_WIDTH-1:0] layer_length [0:1];
    logic [16:0] layer_bits [0:1];
    logic [15:0] active_frame_id;
    logic [5:0] active_stripe_index;
    logic [7:0] active_quality;
    logic [LENGTH_WIDTH-1:0] fragment_offset;
    logic [LENGTH_WIDTH-1:0] fragment_length;
    logic [LENGTH_WIDTH-1:0] payload_index;
    logic [7:0] fragment_index;
    logic [7:0] fragment_count;
    logic [4:0] header_index;
    logic [15:0] record_sequence;
    logic [15:0] crc;
    logic [7:0] tx_byte;
    logic [MEMORY_ADDRESS_WIDTH-1:0] memory_read_address;
    logic [7:0] memory_read_data;
    logic [15:0] gap_remaining;
    logic [15:0] pad_remaining;
    logic continue_layer_after_gap;
    logic start_enhancement_after_gap;
    logic release_bank_after_gap;

    wire read_bank_pending =
        commit_read_sync_2[read_bank] != done_toggle[read_bank];
    wire [LENGTH_WIDTH-1:0] remaining_length =
        layer_length[packet_layer] - fragment_offset;
    wire [LENGTH_WIDTH-1:0] next_fragment_length =
        remaining_length > LENGTH_WIDTH'(FRAGMENT_BYTES)
        ? LENGTH_WIDTH'(FRAGMENT_BYTES) : remaining_length;
    wire [15:0] crc_after_tx_byte = crc16_byte(crc, tx_byte);
    wire last_payload_byte = payload_index + 1'b1 == fragment_length;
    wire last_fragment = fragment_index + 1'b1 == fragment_count;

    function automatic logic [7:0] header_byte(input logic [4:0] index);
        logic [2:0] final_flag;
        begin
            final_flag = (layer_bits[packet_layer] - 1'b1) & 3'h7;
            case (index)
                0: header_byte = 8'hc5;
                1: header_byte = 8'h3a;
                2: header_byte = 8'h01;
                3: header_byte = packet_layer ? 8'h11 : 8'h10;
                4: header_byte = record_sequence[7:0];
                5: header_byte = record_sequence[15:8];
                6: header_byte = active_frame_id[7:0];
                7: header_byte = active_frame_id[15:8];
                8: header_byte = active_frame_id[7:0];
                9: header_byte = active_frame_id[15:8];
                10: header_byte = {2'b00, active_stripe_index};
                11: header_byte = active_quality;
                12: header_byte = fragment_index;
                13: header_byte = fragment_count;
                14: header_byte = last_fragment ? {5'd0, final_flag} : 8'd0;
                15: header_byte = 8'd0;
                16: header_byte = fragment_length[7:0];
                default: header_byte = fragment_length >> 8;
            endcase
        end
    endfunction

    assign packet_active = read_state == HEADER_HIGH
                        || read_state == HEADER_LOW
                        || read_state == PAYLOAD_HIGH
                        || read_state == PAYLOAD_LOW
                        || read_state == CRC_LOW_HIGH
                        || read_state == CRC_LOW_LOW
                        || read_state == CRC_HIGH_HIGH
                        || read_state == CRC_HIGH_LOW
                        || read_state == PAD_HIGH
                        || read_state == PAD_LOW;
    assign packet_data = (read_state == HEADER_LOW
                       || read_state == PAYLOAD_LOW
                       || read_state == CRC_LOW_LOW
                       || read_state == CRC_HIGH_LOW)
                       ? tx_byte[3:0] : tx_byte[7:4];
    assign packet_start = read_state == HEADER_HIGH && header_index == 0;
    assign packet_end = read_state == CRC_HIGH_LOW;
    assign packet_byte_length = 16'd20 + fragment_length;

    always_ff @(posedge read_clk)
        memory_read_data <= packet_memory[memory_read_address];

    always_ff @(posedge read_clk) begin
        if (!read_rst_n) begin
            read_state <= READ_IDLE;
            read_bank <= 1'b0;
            layer_length[0] <= '0;
            layer_length[1] <= '0;
            layer_bits[0] <= '0;
            layer_bits[1] <= '0;
            active_frame_id <= '0;
            active_stripe_index <= '0;
            active_quality <= 8'd24;
            fragment_offset <= '0;
            fragment_length <= '0;
            payload_index <= '0;
            fragment_index <= 8'd0;
            fragment_count <= 8'd0;
            header_index <= 5'd0;
            record_sequence <= 16'd0;
            crc <= 16'hffff;
            tx_byte <= 8'd0;
            memory_read_address <= '0;
            gap_remaining <= 16'd0;
            pad_remaining <= 16'd0;
            continue_layer_after_gap <= 1'b0;
            start_enhancement_after_gap <= 1'b0;
            release_bank_after_gap <= 1'b0;
            packet_layer <= 1'b0;
            packet_count <= 32'd0;
            done_toggle <= 2'b00;
            commit_read_sync_1 <= 2'b00;
            commit_read_sync_2 <= 2'b00;
        end else begin
            commit_read_sync_1 <= commit_toggle;
            commit_read_sync_2 <= commit_read_sync_1;
            if (read_enable) begin
                case (read_state)
                READ_IDLE: begin
                    if (read_bank_pending) begin
                        layer_length[0] <= committed_length[read_bank][0];
                        layer_length[1] <= committed_length[read_bank][1];
                        layer_bits[0] <= committed_bits[read_bank][0];
                        layer_bits[1] <= committed_bits[read_bank][1];
                        active_frame_id <= committed_frame_id[read_bank];
                        active_stripe_index <=
                            committed_stripe_index[read_bank];
                        active_quality <= committed_quality[read_bank];
                        packet_layer <= committed_length[read_bank][0] == 0;
                        fragment_offset <= '0;
                        fragment_index <= 8'd0;
                        read_state <= PREP_RECORD;
                    end
                end
                PREP_RECORD: begin
                    fragment_length <= next_fragment_length;
                    fragment_count <= (layer_length[packet_layer]
                                      + FRAGMENT_BYTES - 1) / FRAGMENT_BYTES;
                    payload_index <= '0;
                    header_index <= 5'd0;
                    crc <= 16'hffff;
                    tx_byte <= 8'hc5;
                    memory_read_address <= {
                        read_bank, packet_layer,
                        fragment_offset[ADDRESS_WIDTH-1:0]
                    };
                    read_state <= HEADER_HIGH;
                end
                HEADER_HIGH: read_state <= HEADER_LOW;
                HEADER_LOW: begin
                    crc <= crc_after_tx_byte;
                    if (header_index == 17) begin
                        tx_byte <= memory_read_data;
                        if (fragment_length > 1)
                            memory_read_address <= {
                                read_bank, packet_layer,
                                fragment_offset[ADDRESS_WIDTH-1:0] + 1'b1
                            };
                        read_state <= PAYLOAD_HIGH;
                    end else begin
                        header_index <= header_index + 1'b1;
                        tx_byte <= header_byte(header_index + 1'b1);
                        read_state <= HEADER_HIGH;
                    end
                end
                PAYLOAD_HIGH: read_state <= PAYLOAD_LOW;
                PAYLOAD_LOW: begin
                    crc <= crc_after_tx_byte;
                    if (last_payload_byte) begin
                        tx_byte <= crc_after_tx_byte[7:0];
                        read_state <= CRC_LOW_HIGH;
                    end else begin
                        payload_index <= payload_index + 1'b1;
                        tx_byte <= memory_read_data;
                        if (payload_index + 2 < fragment_length)
                            memory_read_address <= {
                                read_bank, packet_layer,
                                fragment_offset[ADDRESS_WIDTH-1:0]
                                + payload_index[ADDRESS_WIDTH-1:0] + ADDRESS_WIDTH'(2)
                            };
                        read_state <= PAYLOAD_HIGH;
                    end
                end
                CRC_LOW_HIGH: read_state <= CRC_LOW_LOW;
                CRC_LOW_LOW: begin
                    tx_byte <= crc[15:8];
                    read_state <= CRC_HIGH_HIGH;
                end
                CRC_HIGH_HIGH: read_state <= CRC_HIGH_LOW;
                CRC_HIGH_LOW: begin
                    if (WIRE_RECORD_BYTES > 0
                        && 16'(WIRE_RECORD_BYTES) > packet_byte_length) begin
                        tx_byte <= 8'd0;
                        pad_remaining <=
                            16'(WIRE_RECORD_BYTES) - packet_byte_length;
                        read_state <= PAD_HIGH;
                    end else begin
                        read_state <= FINISH_RECORD;
                    end
                end
                PAD_HIGH: read_state <= PAD_LOW;
                PAD_LOW: begin
                    if (pad_remaining > 1) begin
                        pad_remaining <= pad_remaining - 1'b1;
                        read_state <= PAD_HIGH;
                    end else begin
                        pad_remaining <= 16'd0;
                        read_state <= FINISH_RECORD;
                    end
                end
                FINISH_RECORD: begin
                    packet_count <= packet_count + 1'b1;
                    record_sequence <= record_sequence + 1'b1;
                    continue_layer_after_gap <= !last_fragment;
                    start_enhancement_after_gap <= last_fragment
                        && !packet_layer && layer_length[1] != 0;
                    release_bank_after_gap <= last_fragment
                        && (packet_layer || layer_length[1] == 0);
                    gap_remaining <= gap_cycles;
                    read_state <= READ_GAP;
                end
                default: begin
                    if (gap_remaining > 1) begin
                        gap_remaining <= gap_remaining - 1'b1;
                    end else if (continue_layer_after_gap) begin
                        continue_layer_after_gap <= 1'b0;
                        fragment_offset <= fragment_offset + fragment_length;
                        fragment_index <= fragment_index + 1'b1;
                        read_state <= PREP_RECORD;
                    end else if (start_enhancement_after_gap) begin
                        start_enhancement_after_gap <= 1'b0;
                        packet_layer <= 1'b1;
                        fragment_offset <= '0;
                        fragment_index <= 8'd0;
                        read_state <= PREP_RECORD;
                    end else begin
                        if (release_bank_after_gap) begin
                            done_toggle[read_bank] <=
                                commit_read_sync_2[read_bank];
                            read_bank <= ~read_bank;
                        end
                        release_bank_after_gap <= 1'b0;
                        read_state <= READ_IDLE;
                    end
                end
                endcase
            end
        end
    end
endmodule
