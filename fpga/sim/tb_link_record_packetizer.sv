`timescale 1ns/1ps

module tb_link_record_packetizer;
    logic write_clk = 0;
    logic read_clk = 0;
    always #5 write_clk = ~write_clk;
    always #10 read_clk = ~read_clk;

    logic write_rst_n = 0, read_rst_n = 0;
    logic s_valid = 0, s_layer = 0, s_commit = 0;
    logic [7:0] s_data = 0;
    logic s_ready, s_commit_ready, write_overflow;
    logic packet_active, packet_layer, packet_start, packet_end;
    logic [3:0] packet_data;
    logic [15:0] packet_byte_length;
    logic [31:0] packet_count;

    link_record_packetizer #(
        .WIRE_RECORD_BYTES(920)
    ) dut (
        .write_clk(write_clk), .write_rst_n(write_rst_n),
        .s_valid(s_valid), .s_ready(s_ready), .s_data(s_data),
        .s_layer(s_layer), .s_commit(s_commit),
        .s_commit_ready(s_commit_ready),
        .s_frame_id(16'h1234), .s_stripe_index(6'd17),
        .s_quality(8'd24), .s_base_bits(17'd7997),
        .s_enhancement_bits(17'd53), .write_overflow(write_overflow),
        .read_clk(read_clk), .read_rst_n(read_rst_n), .read_enable(1'b1),
        .gap_cycles(16'd3), .packet_active(packet_active),
        .packet_data(packet_data), .packet_layer(packet_layer),
        .packet_start(packet_start), .packet_end(packet_end),
        .packet_byte_length(packet_byte_length), .packet_count(packet_count)
    );

    task automatic put_byte(input logic layer, input logic [7:0] value);
        begin
            @(negedge write_clk);
            s_layer = layer;
            s_data = value;
            s_valid = 1;
            while (!s_ready) @(negedge write_clk);
            @(negedge write_clk);
            s_valid = 0;
        end
    endtask

    logic [7:0] record [0:1023];
    integer record_size = 0;
    integer nibble_phase = 0;
    integer seen_records = 0;
    integer wire_nibbles = 0;
    logic saw_crc_end = 0;
    logic previous_packet_active = 0;
    integer index;
    reg [15:0] computed_crc;

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

    task automatic validate_record;
        integer payload_length;
        integer payload_index;
        integer expected_size;
        begin
            payload_length = record[16] | (record[17] << 8);
            expected_size = payload_length + 20;
            if (record_size != expected_size) $fatal(1, "record size");
            if (record[0] != 8'hc5 || record[1] != 8'h3a
                || record[2] != 1) $fatal(1, "magic");
            if (record[4] != seen_records || record[5] != 0)
                $fatal(1, "sequence");
            if (record[6] != 8'h34 || record[7] != 8'h12
                || record[8] != 8'h34 || record[9] != 8'h12)
                $fatal(1, "frame id");
            if (record[10] != 17 || record[11] != 24)
                $fatal(1, "stripe metadata");

            if (seen_records == 0) begin
                if (record[3] != 8'h10 || record[12] != 0
                    || record[13] != 2 || record[14] != 0
                    || payload_length != 900) $fatal(1, "base fragment 0");
            end else if (seen_records == 1) begin
                if (record[3] != 8'h10 || record[12] != 1
                    || record[13] != 2 || record[14] != 4
                    || payload_length != 100) $fatal(1, "base fragment 1");
            end else begin
                if (record[3] != 8'h11 || record[12] != 0
                    || record[13] != 1 || record[14] != 4
                    || payload_length != 7) $fatal(1, "enhancement fragment");
            end

            for (payload_index = 0; payload_index < payload_length;
                 payload_index = payload_index + 1) begin
                if (seen_records < 2) begin
                    if (record[18 + payload_index]
                        != ((seen_records * 900 + payload_index) & 8'hff))
                        $fatal(1, "base payload byte %0d", payload_index);
                end else if (record[18 + payload_index]
                             != (8'ha0 + payload_index))
                    $fatal(1, "enhancement payload byte %0d", payload_index);
            end
            computed_crc = 16'hffff;
            for (index = 0; index < record_size - 2; index = index + 1)
                computed_crc = crc_byte(computed_crc, record[index]);
            if (record[record_size-2] != computed_crc[7:0]
                || record[record_size-1] != computed_crc[15:8])
                $fatal(1, "CRC16");
            seen_records = seen_records + 1;
        end
    endtask

    always @(negedge read_clk) begin
        if (packet_active) begin
            if (packet_start) begin
                record_size = 0;
                nibble_phase = 0;
                wire_nibbles = 0;
                saw_crc_end = 0;
            end
            wire_nibbles = wire_nibbles + 1;
            if (saw_crc_end && packet_data != 0)
                $fatal(1, "non-zero padding");
            if (!nibble_phase) begin
                record[record_size][7:4] = packet_data;
                nibble_phase = 1;
            end else begin
                record[record_size][3:0] = packet_data;
                record_size = record_size + 1;
                nibble_phase = 0;
                if (packet_end) begin
                    validate_record();
                    saw_crc_end = 1;
                end
            end
        end
        if (previous_packet_active && !packet_active
            && wire_nibbles != 1840)
            $fatal(1, "wire length %0d", wire_nibbles / 2);
        previous_packet_active = packet_active;
    end

    initial begin
        repeat (5) @(negedge write_clk);
        write_rst_n = 1;
        read_rst_n = 1;
        for (index = 0; index < 1000; index = index + 1)
            put_byte(0, index[7:0]);
        for (index = 0; index < 7; index = index + 1)
            put_byte(1, 8'ha0 + index[7:0]);
        @(negedge write_clk);
        s_commit = 1;
        while (!s_commit_ready) @(negedge write_clk);
        @(negedge write_clk);
        s_commit = 0;
        wait (packet_count == 3);
        repeat (10) @(negedge read_clk);
        if (write_overflow || packet_count != 3)
            $fatal(1, "status mismatch");
        $display("PASS link_record_packetizer records=%0d", seen_records);
        $finish;
    end

    initial begin
        #1000000;
        $fatal(1, "timeout");
    end
endmodule
