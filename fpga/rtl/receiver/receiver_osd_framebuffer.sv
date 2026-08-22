module receiver_osd_framebuffer #(
    parameter integer WORD_COUNT = 5760,
    parameter integer ADDRESS_WIDTH = 13
) (
    input  logic                     write_clk,
    input  logic                     write_rst_n,
    input  logic                     clear_request,
    output logic                     clear_busy,
    output logic                     clear_done,
    input  logic                     write_valid,
    output logic                     write_ready,
    input  logic [ADDRESS_WIDTH-1:0] write_address,
    input  logic [39:0]              write_data,
    input  logic                     pixel_clk,
    input  logic                     pixel_rst_n,
    input  logic [10:0]              x,
    input  logic [9:0]               y,
    input  logic                     data_enable,
    input  logic                     hsync,
    input  logic                     vsync,
    output logic                     osd_mask,
    output logic                     data_enable_out,
    output logic                     hsync_out,
    output logic                     vsync_out
);
    localparam integer BANK_COUNT = 12;
    localparam logic [3:0] BANK_COUNT_4 = 4'd12;
    localparam logic [ADDRESS_WIDTH-1:0] LAST_WORD =
        ADDRESS_WIDTH'(WORD_COUNT - 1);

    logic [ADDRESS_WIDTH-1:0] clear_address;
    logic ram_write_enable;
    logic [ADDRESS_WIDTH-1:0] ram_write_address;
    logic [39:0] ram_write_data;
    wire [3:0] ram_write_bank = ram_write_address[12:9];
    wire [8:0] ram_write_row = ram_write_address[8:0];

    assign write_ready = !clear_busy;
    always_comb begin
        ram_write_enable = 1'b0;
        ram_write_address = write_address;
        ram_write_data = write_data;
        if (clear_busy) begin
            ram_write_enable = 1'b1;
            ram_write_address = clear_address;
            ram_write_data = 40'd0;
        end else if (write_valid && (write_address <= LAST_WORD)) begin
            ram_write_enable = 1'b1;
        end
    end

    always_ff @(posedge write_clk) begin
        clear_done <= 1'b0;
        if (!write_rst_n) begin
            clear_busy <= 1'b1;
            clear_address <= '0;
        end else if (clear_busy) begin
            if (clear_address == LAST_WORD) begin
                clear_busy <= 1'b0;
                clear_done <= 1'b1;
                clear_address <= '0;
            end else begin
                clear_address <= clear_address + 1'b1;
            end
        end else if (clear_request) begin
            clear_busy <= 1'b1;
            clear_address <= '0;
        end
    end

    logic [3:0] word_in_line;
    logic [5:0] bit_in_word;
    logic horizontal_repeat;
    logic [ADDRESS_WIDTH-1:0] read_address;
    wire [3:0] read_bank = read_address[12:9];
    wire [8:0] read_row = read_address[8:0];
    logic [39:0] bank_read_word [0:BANK_COUNT-1];

    genvar bank_index;
    generate
        for (bank_index = 0; bank_index < BANK_COUNT;
             bank_index = bank_index + 1) begin : osd_banks
            logic [9:0] lane0 [0:511];
            logic [9:0] lane1 [0:511];
            logic [9:0] lane2 [0:511];
            logic [9:0] lane3 [0:511];

            always_ff @(posedge write_clk) begin
                if (write_rst_n && ram_write_enable
                    && (ram_write_bank == bank_index)) begin
                    lane0[ram_write_row] <= ram_write_data[9:0];
                    lane1[ram_write_row] <= ram_write_data[19:10];
                    lane2[ram_write_row] <= ram_write_data[29:20];
                    lane3[ram_write_row] <= ram_write_data[39:30];
                end
            end

            always_ff @(posedge pixel_clk) begin
                bank_read_word[bank_index] <= {
                    lane3[read_row], lane2[read_row],
                    lane1[read_row], lane0[read_row]
                };
            end
        end
    endgenerate

    always_comb begin
        read_address = {y[9:1], 4'b0000} + {9'd0, word_in_line};
    end

    logic [3:0] read_bank_d1;
    logic [5:0] bit_index_d1;
    logic [39:0] selected_word;
    logic [5:0] bit_index_d2;
    logic [7:0] selected_byte;
    logic [2:0] bit_index_d3;
    logic de_d1, de_d2, de_d3;
    logic hs_d1, hs_d2, hs_d3;
    logic vs_d1, vs_d2, vs_d3;

    always_ff @(posedge pixel_clk) begin
        if (!pixel_rst_n) begin
            word_in_line <= 4'd0;
            bit_in_word <= 6'd0;
            horizontal_repeat <= 1'b0;
            read_bank_d1 <= 4'd0;
            bit_index_d1 <= 6'd0;
            selected_word <= 40'd0;
            bit_index_d2 <= 6'd0;
            selected_byte <= 8'd0;
            bit_index_d3 <= 3'd0;
            de_d1 <= 1'b0;
            de_d2 <= 1'b0;
            de_d3 <= 1'b0;
            data_enable_out <= 1'b0;
            hs_d1 <= 1'b0;
            hs_d2 <= 1'b0;
            hs_d3 <= 1'b0;
            hsync_out <= 1'b0;
            vs_d1 <= 1'b0;
            vs_d2 <= 1'b0;
            vs_d3 <= 1'b0;
            vsync_out <= 1'b0;
            osd_mask <= 1'b0;
        end else begin
            if (!data_enable) begin
                word_in_line <= 4'd0;
                bit_in_word <= 6'd0;
                horizontal_repeat <= 1'b0;
            end else if (!horizontal_repeat) begin
                horizontal_repeat <= 1'b1;
            end else begin
                horizontal_repeat <= 1'b0;
                if (bit_in_word == 39) begin
                    bit_in_word <= 6'd0;
                    if (word_in_line != 15)
                        word_in_line <= word_in_line + 1'b1;
                end else begin
                    bit_in_word <= bit_in_word + 1'b1;
                end
            end

            read_bank_d1 <= read_bank;
            bit_index_d1 <= bit_in_word;
            de_d1 <= data_enable;
            hs_d1 <= hsync;
            vs_d1 <= vsync;

            if (read_bank_d1 < BANK_COUNT_4)
                selected_word <= bank_read_word[read_bank_d1];
            else
                selected_word <= 40'd0;
            bit_index_d2 <= bit_index_d1;
            de_d2 <= de_d1;
            hs_d2 <= hs_d1;
            vs_d2 <= vs_d1;

            case (bit_index_d2[5:3])
                3'd0: selected_byte <= selected_word[7:0];
                3'd1: selected_byte <= selected_word[15:8];
                3'd2: selected_byte <= selected_word[23:16];
                3'd3: selected_byte <= selected_word[31:24];
                default: selected_byte <= selected_word[39:32];
            endcase
            bit_index_d3 <= bit_index_d2[2:0];
            de_d3 <= de_d2;
            hs_d3 <= hs_d2;
            vs_d3 <= vs_d2;

            osd_mask <= selected_byte[bit_index_d3];
            data_enable_out <= de_d3;
            hsync_out <= hs_d3;
            vsync_out <= vs_d3;
        end
    end

    logic unused_x;
    assign unused_x = (^x) ^ y[0];
endmodule
