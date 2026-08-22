module receiver_parallel_ingress #(
    parameter integer ADDRESS_WIDTH = 12,
    parameter logic [ADDRESS_WIDTH:0] STOP_LEVEL = 2816,
    parameter logic [ADDRESS_WIDTH:0] RESUME_LEVEL = 2048,
    parameter logic [ADDRESS_WIDTH:0] WARNING_LEVEL = 3584,
    parameter logic [ADDRESS_WIDTH:0] HARD_STOP_LEVEL = 4088
) (
    input  logic                     link_clk,
    input  logic                     link_rst_n,
    output logic                     par_clk,
    input  logic                     par_cs,
    input  logic [3:0]               par_data,

    input  logic                     read_clk,
    input  logic                     read_rst_n,
    output logic [9:0]               output_entry,
    output logic                     output_valid,
    input  logic                     output_ready,

    output logic [ADDRESS_WIDTH:0]   write_level,
    output logic [ADDRESS_WIDTH:0]   read_level,
    output logic                     par_clock_enabled,
    output logic                     warning_level,
    output logic                     overflow_error,
    output logic                     framing_error
);
    localparam integer DEPTH = 1 << ADDRESS_WIDTH;
    localparam logic [1:0] ENTRY_DATA = 2'b00;
    localparam logic [1:0] ENTRY_START_DATA = 2'b01;
    localparam logic [1:0] ENTRY_END = 2'b10;

    logic [9:0] memory [0:DEPTH-1];

    logic [ADDRESS_WIDTH:0] write_pointer_binary;
    logic [ADDRESS_WIDTH:0] write_pointer_gray;
    logic [ADDRESS_WIDTH:0] read_pointer_binary;
    logic [ADDRESS_WIDTH:0] read_pointer_gray;
    logic [ADDRESS_WIDTH:0] read_gray_sync1, read_gray_sync2;
    logic [ADDRESS_WIDTH:0] write_gray_sync1, write_gray_sync2;
    logic [ADDRESS_WIDTH:0] read_binary_link;
    logic [ADDRESS_WIDTH:0] write_binary_read;
    logic [ADDRESS_WIDTH:0] write_pointer_next;
    logic [ADDRESS_WIDTH:0] write_gray_next;
    logic fifo_full;

    logic clock_enable_request;
    logic throttle_pending;
    logic transaction_active;
    logic first_byte_pending;
    logic nibble_phase;
    logic [3:0] upper_nibble;

    function automatic [ADDRESS_WIDTH:0] binary_to_gray(
        input [ADDRESS_WIDTH:0] value
    );
        binary_to_gray = (value >> 1) ^ value;
    endfunction

    function automatic [ADDRESS_WIDTH:0] gray_to_binary(
        input [ADDRESS_WIDTH:0] value
    );
        integer bit_index;
        begin
            gray_to_binary[ADDRESS_WIDTH] = value[ADDRESS_WIDTH];
            for (bit_index = ADDRESS_WIDTH - 1; bit_index >= 0;
                 bit_index = bit_index - 1)
                gray_to_binary[bit_index] =
                    gray_to_binary[bit_index + 1] ^ value[bit_index];
        end
    endfunction

    always_comb begin
        read_binary_link = gray_to_binary(read_gray_sync2);
        write_binary_read = gray_to_binary(write_gray_sync2);
        write_level = write_pointer_binary - read_binary_link;
        read_level = write_binary_read - read_pointer_binary;
        write_pointer_next = write_pointer_binary + 1'b1;
        write_gray_next = binary_to_gray(write_pointer_next);
        fifo_full = write_gray_next
                    == {~read_gray_sync2[ADDRESS_WIDTH:ADDRESS_WIDTH-1],
                        read_gray_sync2[ADDRESS_WIDTH-2:0]};
        warning_level = write_level >= WARNING_LEVEL;
    end

    // The gate control changes only while link_clk is low, so PAR_CLK never
    // contains a shortened high pulse. The internal write clock keeps running
    // while the external ESP32 PARLIO clock is paused, allowing FIFO pointers
    // to synchronize and the link to resume without software intervention.
    always_ff @(negedge link_clk or negedge link_rst_n) begin
        if (!link_rst_n)
            par_clock_enabled <= 1'b0;
        else
            par_clock_enabled <= clock_enable_request;
    end
    always_comb par_clk = link_clk & par_clock_enabled;

    always_ff @(posedge link_clk or negedge link_rst_n) begin
        if (!link_rst_n) begin
            read_gray_sync1 <= '0;
            read_gray_sync2 <= '0;
            write_pointer_binary <= '0;
            write_pointer_gray <= '0;
            clock_enable_request <= 1'b0;
            throttle_pending <= 1'b0;
            transaction_active <= 1'b0;
            first_byte_pending <= 1'b0;
            nibble_phase <= 1'b0;
            upper_nibble <= 4'd0;
            overflow_error <= 1'b0;
            framing_error <= 1'b0;
        end else begin
            read_gray_sync1 <= read_pointer_gray;
            read_gray_sync2 <= read_gray_sync1;

            if (!clock_enable_request
                && (write_level <= RESUME_LEVEL)) begin
                clock_enable_request <= 1'b1;
                throttle_pending <= 1'b0;
            end

            if (write_level >= STOP_LEVEL)
                throttle_pending <= 1'b1;

            // A corrupt or overlong transaction is paused in place before it
            // can overflow RAM. Normal traffic is stopped only after PAR_CS
            // falls, so the ESP32 always sees a clean packet boundary.
            if (write_level >= HARD_STOP_LEVEL)
                clock_enable_request <= 1'b0;

            if (par_clock_enabled && par_cs) begin
                if (!transaction_active) begin
                    transaction_active <= 1'b1;
                    first_byte_pending <= 1'b1;
                    nibble_phase <= 1'b1;
                    upper_nibble <= par_data;
                end else if (!nibble_phase) begin
                    nibble_phase <= 1'b1;
                    upper_nibble <= par_data;
                end else begin
                    nibble_phase <= 1'b0;
                    if (!fifo_full) begin
                        memory[write_pointer_binary[ADDRESS_WIDTH-1:0]] <= {
                            first_byte_pending
                                ? ENTRY_START_DATA : ENTRY_DATA,
                            upper_nibble, par_data
                        };
                        write_pointer_binary <= write_pointer_next;
                        write_pointer_gray <= write_gray_next;
                        first_byte_pending <= 1'b0;
                    end else begin
                        overflow_error <= 1'b1;
                        clock_enable_request <= 1'b0;
                    end
                end
            end else if (transaction_active && !par_cs) begin
                transaction_active <= 1'b0;
                if (nibble_phase)
                    framing_error <= 1'b1;
                nibble_phase <= 1'b0;
                if (!fifo_full) begin
                    memory[write_pointer_binary[ADDRESS_WIDTH-1:0]] <= {
                        ENTRY_END, 8'd0
                    };
                    write_pointer_binary <= write_pointer_next;
                    write_pointer_gray <= write_gray_next;
                end else begin
                    overflow_error <= 1'b1;
                    clock_enable_request <= 1'b0;
                end
                if (throttle_pending || (write_level >= STOP_LEVEL))
                    clock_enable_request <= 1'b0;
            end
        end
    end

    // Synchronous read port: the prefetched entry lives in output_entry until
    // accepted. Advancing the RAM pointer here makes the storage infer as a
    // true dual-clock block RAM instead of a large asynchronous LUT memory.
    always_ff @(posedge read_clk) begin
        if (!read_rst_n) begin
            write_gray_sync1 <= '0;
            write_gray_sync2 <= '0;
            read_pointer_binary <= '0;
            read_pointer_gray <= '0;
            output_entry <= 10'd0;
            output_valid <= 1'b0;
        end else begin
            write_gray_sync1 <= write_pointer_gray;
            write_gray_sync2 <= write_gray_sync1;
            if (!output_valid || output_ready) begin
                if (read_pointer_gray != write_gray_sync2) begin
                    output_entry <=
                        memory[read_pointer_binary[ADDRESS_WIDTH-1:0]];
                    output_valid <= 1'b1;
                    read_pointer_binary <= read_pointer_binary + 1'b1;
                    read_pointer_gray <= binary_to_gray(
                        read_pointer_binary + 1'b1
                    );
                end else begin
                    output_valid <= 1'b0;
                end
            end
        end
    end
endmodule
