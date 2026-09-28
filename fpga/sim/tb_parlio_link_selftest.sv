`timescale 1ns/1ps

module tb_parlio_link_selftest;
    logic write_clk = 0;
    logic read_clk = 0;
    always #5 write_clk = ~write_clk;
    always #10 read_clk = ~read_clk;

    logic write_rst_n = 0;
    logic read_rst_n = 0;
    logic s_valid, s_ready, s_layer, s_commit, s_commit_ready;
    logic [7:0] s_data;
    logic [15:0] frame_id, record_index;
    logic [5:0] stripe_index;
    logic [7:0] quality;
    logic [16:0] base_bits, enhancement_bits;
    logic write_overflow;
    logic packet_active, packet_layer, packet_start, packet_end;
    logic [3:0] packet_data;
    logic [15:0] packet_byte_length;
    logic [31:0] packet_count;

    parlio_link_test_producer source (
        .clk(write_clk), .rst_n(write_rst_n),
        .s_valid(s_valid), .s_ready(s_ready),
        .s_data(s_data), .s_layer(s_layer),
        .s_commit(s_commit), .s_commit_ready(s_commit_ready),
        .frame_id(frame_id), .stripe_index(stripe_index),
        .quality(quality), .base_bits(base_bits),
        .enhancement_bits(enhancement_bits),
        .record_index(record_index)
    );

    link_record_packetizer #(
        .MAX_LAYER_BYTES(2048), .FRAGMENT_BYTES(900),
        .WIRE_RECORD_BYTES(920)
    ) packetizer (
        .write_clk(write_clk), .write_rst_n(write_rst_n),
        .s_valid(s_valid), .s_ready(s_ready), .s_data(s_data),
        .s_layer(s_layer), .s_commit(s_commit),
        .s_commit_ready(s_commit_ready), .s_frame_id(frame_id),
        .s_stripe_index(stripe_index), .s_quality(quality),
        .s_base_bits(base_bits), .s_enhancement_bits(enhancement_bits),
        .write_overflow(write_overflow),
        .read_clk(read_clk), .read_rst_n(read_rst_n), .read_enable(1'b1),
        .gap_cycles(16'd0), .packet_active(packet_active),
        .packet_data(packet_data), .packet_layer(packet_layer),
        .packet_start(packet_start), .packet_end(packet_end),
        .packet_byte_length(packet_byte_length), .packet_count(packet_count)
    );

    logic [7:0] record [0:919];
    integer logical_size = 0;
    integer wire_bytes = 0;
    integer nibble_phase = 0;
    integer seen_records = 0;
    integer index;
    integer payload_length;
    reg [15:0] computed_crc;
    logic previous_packet_active = 0;
    logic saw_packet_end = 0;

    function automatic [15:0] crc_byte(
        input [15:0] crc_in, input [7:0] data_in
    );
        reg [15:0] value;
        integer bit_index;
        begin
            value = crc_in ^ {data_in, 8'd0};
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1)
                value = value[15] ? (value << 1) ^ 16'h1021
                                  : (value << 1);
            crc_byte = value;
        end
    endfunction

    function automatic integer expected_length(input integer number);
        begin
            case (number & 7)
                0: expected_length = 1;
                1: expected_length = 7;
                2: expected_length = 31;
                3: expected_length = 127;
                4: expected_length = 257;
                5: expected_length = 511;
                6: expected_length = 899;
                default: expected_length = 900;
            endcase
        end
    endfunction

    function automatic [7:0] expected_byte(
        input integer number, input integer offset
    );
        reg [7:0] offset_byte;
        begin
            offset_byte = offset[7:0];
            expected_byte = 8'ha5 ^ number[7:0] ^ offset_byte
                          ^ {offset_byte[3:0], offset_byte[7:4]};
        end
    endfunction

    task automatic validate_record;
        integer expected_payload;
        begin
            expected_payload = expected_length(seen_records);
            if (logical_size != expected_payload + 20)
                $fatal(1, "record %0d logical size %0d", seen_records,
                       logical_size);
            if (record[0] != 8'hc5 || record[1] != 8'h3a
                || record[2] != 1 || record[3] != 8'h10)
                $fatal(1, "record %0d header", seen_records);
            if ({record[5], record[4]} != seen_records[15:0]
                || {record[7], record[6]} != seen_records[15:0]
                || {record[9], record[8]} != seen_records[15:0])
                $fatal(1, "record %0d sequence/frame", seen_records);
            if (record[10] != (seen_records & 6'h3f)
                || record[11] != 8'ha5 || record[12] != 0
                || record[13] != 1 || record[14] != 7
                || record[15] != 0)
                $fatal(1, "record %0d metadata", seen_records);
            payload_length = record[16] | (record[17] << 8);
            if (payload_length != expected_payload)
                $fatal(1, "record %0d payload length %0d", seen_records,
                       payload_length);
            for (index = 0; index < payload_length; index = index + 1)
                if (record[18 + index] != expected_byte(seen_records, index))
                    $fatal(1, "record %0d payload byte %0d", seen_records,
                           index);
            computed_crc = 16'hffff;
            for (index = 0; index < logical_size - 2; index = index + 1)
                computed_crc = crc_byte(computed_crc, record[index]);
            if (record[logical_size - 2] != computed_crc[7:0]
                || record[logical_size - 1] != computed_crc[15:8])
                $fatal(1, "record %0d CRC", seen_records);
            seen_records = seen_records + 1;
        end
    endtask

    always @(negedge read_clk) begin
        if (packet_active) begin
            if (packet_start) begin
                logical_size = 0;
                wire_bytes = 0;
                nibble_phase = 0;
                saw_packet_end = 0;
            end
            if (saw_packet_end && packet_data != 0)
                $fatal(1, "record %0d non-zero padding", seen_records);
            if (!nibble_phase) begin
                record[wire_bytes][7:4] = packet_data;
                nibble_phase = 1;
            end else begin
                record[wire_bytes][3:0] = packet_data;
                wire_bytes = wire_bytes + 1;
                nibble_phase = 0;
                if (packet_end) begin
                    logical_size = wire_bytes;
                    validate_record();
                    saw_packet_end = 1;
                end
            end
        end
        if (previous_packet_active && !packet_active && wire_bytes != 920)
            $fatal(1, "wire record has %0d bytes", wire_bytes);
        previous_packet_active = packet_active;
    end

    initial begin
        repeat (5) @(negedge write_clk);
        write_rst_n = 1;
        read_rst_n = 1;
        wait (seen_records == 256);
        repeat (10) @(negedge read_clk);
        if (write_overflow || packet_count < 256)
            $fatal(1, "status overflow=%0d count=%0d",
                   write_overflow, packet_count);
        $display("PASS parlio_link_selftest records=%0d", seen_records);
        $finish;
    end

    initial begin
        #30000000;
        $fatal(1, "timeout after %0d records", seen_records);
    end
endmodule
