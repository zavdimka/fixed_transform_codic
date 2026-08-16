module spi_debug_slave #(
    parameter integer INDEX_WIDTH = 10
) (
    input  logic                   clk,
    input  logic                   rst_n,
    input  logic                   spi_cs_n,
    input  logic                   spi_sck,
    input  logic                   spi_mosi,
    output logic                   spi_miso,

    output logic                   frame_start,
    output logic                   frame_end,
    output logic                   active,
    output logic                   rx_valid,
    output logic [7:0]             rx_data,
    output logic [INDEX_WIDTH-1:0] rx_index,
    output logic [INDEX_WIDTH-1:0] tx_index,
    input  logic [7:0]             tx_data,
    output logic                   framing_error
);
    logic [2:0] cs_sync;
    logic [2:0] sck_sync;
    logic [1:0] mosi_sync;
    logic [6:0] rx_shift;
    logic [6:0] tx_shift;
    logic [2:0] bit_count;
    logic       reload_tx;

    wire cs_falling = cs_sync[2] && !cs_sync[1];
    wire cs_rising = !cs_sync[2] && cs_sync[1];
    wire sck_rising = !sck_sync[2] && sck_sync[1];
    wire sck_falling = sck_sync[2] && !sck_sync[1];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            cs_sync <= 3'b111;
            sck_sync <= 3'b000;
            mosi_sync <= 2'b00;
            rx_shift <= 7'd0;
            tx_shift <= 7'd0;
            bit_count <= 3'd0;
            reload_tx <= 1'b0;
            frame_start <= 1'b0;
            frame_end <= 1'b0;
            active <= 1'b0;
            rx_valid <= 1'b0;
            rx_data <= 8'd0;
            rx_index <= '0;
            tx_index <= '0;
            spi_miso <= 1'b0;
            framing_error <= 1'b0;
        end else begin
            cs_sync <= {cs_sync[1:0], spi_cs_n};
            sck_sync <= {sck_sync[1:0], spi_sck};
            mosi_sync <= {mosi_sync[0], spi_mosi};
            frame_start <= 1'b0;
            frame_end <= 1'b0;
            rx_valid <= 1'b0;

            if (cs_falling) begin
                active <= 1'b1;
                frame_start <= 1'b1;
                rx_shift <= 7'd0;
                tx_shift <= tx_data[6:0];
                bit_count <= 3'd0;
                reload_tx <= 1'b0;
                rx_index <= '0;
                tx_index <= '0;
                spi_miso <= tx_data[7];
            end else if (cs_rising) begin
                active <= 1'b0;
                frame_end <= 1'b1;
                spi_miso <= 1'b0;
                if (bit_count != 3'd0)
                    framing_error <= 1'b1;
            end else if (active) begin
                if (sck_rising) begin
                    rx_shift <= {rx_shift[5:0], mosi_sync[1]};
                    if (bit_count == 3'd7) begin
                        rx_valid <= 1'b1;
                        rx_data <= {rx_shift[6:0], mosi_sync[1]};
                        rx_index <= tx_index;
                        tx_index <= tx_index + 1'b1;
                        bit_count <= 3'd0;
                        reload_tx <= 1'b1;
                    end else begin
                        bit_count <= bit_count + 1'b1;
                    end
                end

                if (sck_falling) begin
                    if (reload_tx) begin
                        tx_shift <= tx_data[6:0];
                        spi_miso <= tx_data[7];
                        reload_tx <= 1'b0;
                    end else begin
                        tx_shift <= {tx_shift[5:0], 1'b0};
                        spi_miso <= tx_shift[6];
                    end
                end
            end
        end
    end
endmodule
