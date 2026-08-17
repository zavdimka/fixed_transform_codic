module async_nibble_fifo #(
    parameter integer ADDRESS_WIDTH = 5
) (
    input  logic       write_clk,
    input  logic       write_rst_n,
    input  logic       write_valid,
    output logic       write_ready,
    input  logic [3:0] write_data,
    input  logic       write_last,

    input  logic       read_clk,
    input  logic       read_rst_n,
    output logic       read_valid,
    input  logic       read_ready,
    output logic [3:0] read_data,
    output logic       read_last
);
    localparam integer POINTER_WIDTH = ADDRESS_WIDTH + 1;
    localparam integer DEPTH = 1 << ADDRESS_WIDTH;

    logic [4:0] memory [0:DEPTH-1];
    logic [POINTER_WIDTH-1:0] write_binary;
    logic [POINTER_WIDTH-1:0] write_gray;
    logic [POINTER_WIDTH-1:0] read_binary;
    logic [POINTER_WIDTH-1:0] read_gray;
    logic write_full;
    logic read_empty;

    (* async_reg = "true" *) logic [POINTER_WIDTH-1:0]
        read_gray_write_sync1, read_gray_write_sync2;
    (* async_reg = "true" *) logic [POINTER_WIDTH-1:0]
        write_gray_read_sync1, write_gray_read_sync2;

    wire write_fire = write_valid && write_ready;
    wire read_fire = read_valid && read_ready;
    wire [POINTER_WIDTH-1:0] write_binary_next =
        write_binary + {{(POINTER_WIDTH-1){1'b0}}, write_fire};
    wire [POINTER_WIDTH-1:0] read_binary_next =
        read_binary + {{(POINTER_WIDTH-1){1'b0}}, read_fire};
    wire [POINTER_WIDTH-1:0] write_gray_next =
        (write_binary_next >> 1) ^ write_binary_next;
    wire [POINTER_WIDTH-1:0] read_gray_next =
        (read_binary_next >> 1) ^ read_binary_next;
    wire write_full_next = write_gray_next == {
        ~read_gray_write_sync2[POINTER_WIDTH-1:POINTER_WIDTH-2],
        read_gray_write_sync2[POINTER_WIDTH-3:0]
    };
    wire read_empty_next = read_gray_next == write_gray_read_sync2;

    assign write_ready = !write_full;
    assign read_valid = !read_empty;
    assign {read_last, read_data} = memory[read_binary[ADDRESS_WIDTH-1:0]];

    always_ff @(posedge write_clk) begin
        if (!write_rst_n) begin
            write_binary <= '0;
            write_gray <= '0;
            write_full <= 1'b0;
        end else begin
            if (write_fire)
                memory[write_binary[ADDRESS_WIDTH-1:0]] <= {
                    write_last, write_data
                };
            write_binary <= write_binary_next;
            write_gray <= write_gray_next;
            write_full <= write_full_next;
        end
    end

    always_ff @(posedge read_clk) begin
        if (!read_rst_n) begin
            read_binary <= '0;
            read_gray <= '0;
            read_empty <= 1'b1;
        end else begin
            read_binary <= read_binary_next;
            read_gray <= read_gray_next;
            read_empty <= read_empty_next;
        end
    end

    always_ff @(posedge write_clk) begin
        if (!write_rst_n) begin
            read_gray_write_sync1 <= '0;
            read_gray_write_sync2 <= '0;
        end else begin
            read_gray_write_sync1 <= read_gray;
            read_gray_write_sync2 <= read_gray_write_sync1;
        end
    end

    always_ff @(posedge read_clk) begin
        if (!read_rst_n) begin
            write_gray_read_sync1 <= '0;
            write_gray_read_sync2 <= '0;
        end else begin
            write_gray_read_sync1 <= write_gray;
            write_gray_read_sync2 <= write_gray_read_sync1;
        end
    end
endmodule
