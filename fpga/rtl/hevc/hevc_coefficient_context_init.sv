`timescale 1ns/1ps


module hevc_coefficient_context_init (
    input  logic       clk,
    input  logic       rst_n,

    input  logic       start_valid,
    output logic       start_ready,
    input  logic [1:0] slice_type,
    input  logic [5:0] qp,

    output logic       cfg_valid,
    input  logic       cfg_ready,
    output logic [7:0] cfg_context_address,
    output logic [5:0] cfg_state_index,
    output logic       cfg_mps,

    output logic       done,
    output logic       parameter_error,
    output logic       busy
);
    typedef enum logic [1:0] {
        IDLE,
        ROM_READ,
        CONFIG_WRITE
    } state_t;
    state_t state;

    logic [1:0] slice_type_register;
    logic [5:0] qp_register;
    logic [7:0] context_address_register;
    logic [9:0] rom_read_address;
    logic [7:0] rom_init_value;

    logic signed [6:0] slope;
    logic signed [7:0] offset;
    logic signed [13:0] slope_times_qp;
    logic signed [13:0] unclipped_init_state;
    logic [6:0] init_state;

    assign start_ready = (state == IDLE);
    assign cfg_valid = (state == CONFIG_WRITE);
    assign cfg_context_address = context_address_register;
    assign busy = (state != IDLE);
    always_comb begin
        case (slice_type_register)
            2'd0: rom_read_address = {2'b00, context_address_register};
            2'd1: rom_read_address = 10'd192 + {2'b00, context_address_register};
            default: rom_read_address = 10'd384 + {2'b00, context_address_register};
        endcase
    end

    always_comb begin
        slope =
            $signed({3'b000, rom_init_value[7:4]}) * 7'sd5 - 7'sd45;
        offset =
            $signed({1'b0, rom_init_value[3:0], 3'b000}) - 8'sd16;
        slope_times_qp = slope * $signed({1'b0, qp_register});
        unclipped_init_state =
            (slope_times_qp >>> 4) +
            $signed({{6{offset[7]}}, offset});

        if (unclipped_init_state < 14'sd1) begin
            init_state = 7'd1;
        end else if (unclipped_init_state > 14'sd126) begin
            init_state = 7'd126;
        end else begin
            init_state = unclipped_init_state[6:0];
        end

        if (init_state >= 7'd64) begin
            cfg_state_index = init_state[5:0];
            cfg_mps = 1'b1;
        end else begin
            cfg_state_index = 6'd63 - init_state[5:0];
            cfg_mps = 1'b0;
        end
    end

    hevc_coefficient_context_init_rom init_rom (
        .clk(clk),
        .read_enable(state == ROM_READ),
        .read_address(rom_read_address),
        .read_value(rom_init_value)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            slice_type_register <= 2'd0;
            qp_register <= 6'd0;
            context_address_register <= 8'd0;
            done <= 1'b0;
            parameter_error <= 1'b0;
        end else begin
            done <= 1'b0;
            parameter_error <= 1'b0;

            case (state)
                IDLE: begin
                    if (start_valid && start_ready) begin
                        if (slice_type <= 2'd2) begin
                            slice_type_register <= slice_type;
                            qp_register <= (qp > 6'd51) ? 6'd51 : qp;
                            context_address_register <= 8'd0;
                            state <= ROM_READ;
                        end else begin
                            parameter_error <= 1'b1;
                        end
                    end
                end

                ROM_READ: begin
                    state <= CONFIG_WRITE;
                end

                CONFIG_WRITE: begin
                    if (cfg_valid && cfg_ready) begin
                        if (context_address_register == 8'd191) begin
                            done <= 1'b1;
                            state <= IDLE;
                        end else begin
                            context_address_register <=
                                context_address_register + 1'b1;
                            state <= ROM_READ;
                        end
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end
endmodule
