module layer_packet_pingpong #(
    parameter integer MAX_PACKET_BYTES = 2048,
    parameter integer ADDRESS_WIDTH = $clog2(MAX_PACKET_BYTES)
) (
    input  logic                     write_clk,
    input  logic                     write_rst_n,
    input  logic                     s_valid,
    output logic                     s_ready,
    input  logic [7:0]               s_data,
    input  logic                     s_layer,
    input  logic                     s_commit,
    output logic                     s_commit_ready,
    output logic                     write_overflow,

    input  logic                     read_clk,
    input  logic                     read_rst_n,
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
    localparam logic [LENGTH_WIDTH-1:0] MAX_LENGTH =
        LENGTH_WIDTH'(MAX_PACKET_BYTES);

    localparam integer MEMORY_ADDRESS_WIDTH = ADDRESS_WIDTH + 2;
    localparam integer MEMORY_DEPTH = MAX_PACKET_BYTES * 4;
    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    logic [7:0] packet_memory [0:MEMORY_DEPTH-1];

    logic write_bank;
    logic [LENGTH_WIDTH-1:0] write_length_base;
    logic [LENGTH_WIDTH-1:0] write_length_enhancement;
    logic [LENGTH_WIDTH-1:0] committed_base_length [0:1];
    logic [LENGTH_WIDTH-1:0] committed_enhancement_length [0:1];
    logic [1:0] commit_toggle;
    logic [1:0] done_toggle;

    (* async_reg = "true" *) logic [1:0] done_write_sync_1;
    (* async_reg = "true" *) logic [1:0] done_write_sync_2;
    (* async_reg = "true" *) logic [1:0] commit_read_sync_1;
    (* async_reg = "true" *) logic [1:0] commit_read_sync_2;

    wire write_bank_available =
        done_write_sync_2[write_bank] == commit_toggle[write_bank];
    wire [LENGTH_WIDTH-1:0] selected_write_length = s_layer
        ? write_length_enhancement : write_length_base;

    assign s_ready = write_bank_available;
    assign s_commit_ready = write_bank_available;

    always_ff @(posedge write_clk) begin
        if (!write_rst_n) begin
            write_bank <= 1'b0;
            write_length_base <= '0;
            write_length_enhancement <= '0;
            committed_base_length[0] <= '0;
            committed_base_length[1] <= '0;
            committed_enhancement_length[0] <= '0;
            committed_enhancement_length[1] <= '0;
            commit_toggle <= 2'b00;
            done_write_sync_1 <= 2'b00;
            done_write_sync_2 <= 2'b00;
            write_overflow <= 1'b0;
        end else begin
            done_write_sync_1 <= done_toggle;
            done_write_sync_2 <= done_write_sync_1;

            if (s_valid && s_ready) begin
                if (selected_write_length < MAX_LENGTH) begin
                    packet_memory[{
                        write_bank, s_layer,
                        selected_write_length[ADDRESS_WIDTH-1:0]
                    }] <= s_data;

                    if (s_layer)
                        write_length_enhancement <=
                            write_length_enhancement + 1'b1;
                    else
                        write_length_base <= write_length_base + 1'b1;
                end else begin
                    // Do not deadlock the codec if a bad budget is supplied.
                    // The packet remains bounded and software can reject it.
                    write_overflow <= 1'b1;
                end
            end

            if (s_commit && s_commit_ready) begin
                committed_base_length[write_bank] <= write_length_base;
                committed_enhancement_length[write_bank] <=
                    write_length_enhancement;
                commit_toggle[write_bank] <= ~commit_toggle[write_bank];
                write_bank <= ~write_bank;
                write_length_base <= '0;
                write_length_enhancement <= '0;
            end
        end
    end

    typedef enum logic [2:0] {
        READ_IDLE, READ_PREFETCH, READ_LOAD, READ_HIGH, READ_LOW, READ_GAP
    } read_state_t;
    read_state_t read_state;
    logic read_bank;
    logic [LENGTH_WIDTH-1:0] active_enhancement_length;
    logic [LENGTH_WIDTH-1:0] active_length;
    logic [ADDRESS_WIDTH-1:0] read_address;
    logic [7:0] read_byte;
    logic [7:0] memory_read_data;
    logic [MEMORY_ADDRESS_WIDTH-1:0] memory_read_address;
    logic [15:0] gap_remaining;
    logic start_enhancement_after_gap;
    logic release_bank_after_gap;

    wire read_bank_pending =
        commit_read_sync_2[read_bank] != done_toggle[read_bank];
    wire active_last_byte =
        {1'b0, read_address} + 1'b1 == active_length;

    assign packet_active = (read_state == READ_HIGH)
                        || (read_state == READ_LOW);
    assign packet_data = read_state == READ_LOW
                       ? read_byte[3:0] : read_byte[7:4];
    assign packet_start = (read_state == READ_HIGH)
                       && (read_address == '0);
    assign packet_end = (read_state == READ_LOW) && active_last_byte;
    assign packet_byte_length = {{(16-LENGTH_WIDTH){1'b0}}, active_length};

    always_ff @(posedge read_clk) begin
        if (!read_rst_n) begin
            read_state <= READ_IDLE;
            read_bank <= 1'b0;
            active_enhancement_length <= '0;
            active_length <= '0;
            read_address <= '0;
            read_byte <= 8'd0;
            memory_read_address <= '0;
            gap_remaining <= 16'd0;
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

            case (read_state)
                READ_IDLE: begin
                    if (read_bank_pending) begin
                        active_enhancement_length <=
                            committed_enhancement_length[read_bank];
                        read_address <= '0;
                        if (committed_base_length[read_bank] != 0) begin
                            packet_layer <= 1'b0;
                            active_length <=
                                committed_base_length[read_bank];
                            memory_read_address <= {
                                read_bank, 1'b0, {ADDRESS_WIDTH{1'b0}}
                            };
                            read_state <= READ_PREFETCH;
                        end else if (committed_enhancement_length[read_bank]
                                     != 0) begin
                            packet_layer <= 1'b1;
                            active_length <=
                                committed_enhancement_length[read_bank];
                            memory_read_address <= {
                                read_bank, 1'b1, {ADDRESS_WIDTH{1'b0}}
                            };
                            read_state <= READ_PREFETCH;
                        end else begin
                            done_toggle[read_bank] <=
                                commit_read_sync_2[read_bank];
                            read_bank <= ~read_bank;
                        end
                    end
                end

                READ_PREFETCH: read_state <= READ_LOAD;

                READ_LOAD: begin
                    read_byte <= memory_read_data;
                    if (active_length > 1)
                        memory_read_address <= {
                            read_bank, packet_layer,
                            {{(ADDRESS_WIDTH-1){1'b0}}, 1'b1}
                        };
                    read_state <= READ_HIGH;
                end

                READ_HIGH: begin
                    read_state <= READ_LOW;
                end

                READ_LOW: begin
                    if (active_last_byte) begin
                        packet_count <= packet_count + 1'b1;
                        start_enhancement_after_gap <= !packet_layer
                            && (active_enhancement_length != 0);
                        release_bank_after_gap <= packet_layer
                            || (active_enhancement_length == 0);
                        gap_remaining <= gap_cycles;
                        if (gap_cycles == 0) begin
                            if (!packet_layer
                                && (active_enhancement_length != 0)) begin
                                packet_layer <= 1'b1;
                                active_length <= active_enhancement_length;
                                read_address <= '0;
                                memory_read_address <= {
                                    read_bank, 1'b1,
                                    {ADDRESS_WIDTH{1'b0}}
                                };
                                read_state <= READ_PREFETCH;
                            end else begin
                                done_toggle[read_bank] <=
                                    commit_read_sync_2[read_bank];
                                read_bank <= ~read_bank;
                                read_state <= READ_IDLE;
                            end
                        end else begin
                            read_state <= READ_GAP;
                        end
                    end else begin
                        read_address <= read_address + 1'b1;
                        read_byte <= memory_read_data;
                        if ({1'b0, read_address} + 2 < active_length)
                            memory_read_address <= {
                                read_bank, packet_layer,
                                read_address + ADDRESS_WIDTH'(2)
                            };
                        read_state <= READ_HIGH;
                    end
                end

                default: begin // READ_GAP
                    if (gap_remaining > 1) begin
                        gap_remaining <= gap_remaining - 1'b1;
                    end else if (start_enhancement_after_gap) begin
                        start_enhancement_after_gap <= 1'b0;
                        packet_layer <= 1'b1;
                        active_length <= active_enhancement_length;
                        read_address <= '0;
                        memory_read_address <= {
                            read_bank, 1'b1, {ADDRESS_WIDTH{1'b0}}
                        };
                        read_state <= READ_PREFETCH;
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


    // Canonical synchronous read port.  Keeping the address mux outside the
    // memory access is required for Efinity to infer EBR instead of flops.
    always_ff @(posedge read_clk)
        memory_read_data <= packet_memory[memory_read_address];
endmodule
