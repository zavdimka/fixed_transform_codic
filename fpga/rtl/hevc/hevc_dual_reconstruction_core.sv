// A size8 chroma command is one paired transaction: 64 raster-order Cb samples
// followed by 64 raster-order Cr samples. Luma remains one 256-sample command.
module hevc_dual_reconstruction_core (
    input logic clk, input logic rst_n,
    input logic command_valid, output logic command_ready,
    input logic command_size8, input logic command_chroma,
    input logic [1:0] command_quality,
    input logic s_valid, output logic s_ready,
    input logic [7:0] s_prediction, input logic signed [8:0] s_residual,
    output logic coefficient_valid, input logic coefficient_ready,
    output logic signed [15:0] coefficient_data,
    output logic [3:0] coefficient_x, output logic [3:0] coefficient_y,
    output logic coefficient_nonzero, output logic coefficient_block_last,
    output logic m_valid, input logic m_ready,
    output logic [7:0] m_reconstructed,
    output logic [3:0] m_x, output logic [3:0] m_y,
    output logic m_block_last, output logic m_block_error,
    output logic done, output logic busy
);
    typedef enum logic [1:0] {F_IDLE, F_COMMAND, F_LOAD, F_QUANT} fstate_t;
    typedef enum logic [1:0] {I_IDLE, I_COMMAND, I_REPLAY, I_RECON} istate_t;
    localparam logic [1:0] BANK_FREE = 2'd0, BANK_FORWARD = 2'd1,
                           BANK_READY = 2'd2, BANK_INVERSE = 2'd3;

    fstate_t fstate;
    istate_t istate;
    logic [1:0] bank_state [0:3];
    logic bank_size8 [0:3], bank_pair8 [0:3], bank_error [0:3];
    logic [1:0] write_bank, read_bank, forward_bank, inverse_bank;
    logic f_size8, f_pair8, f_chroma, i_size8, i_pair8;
    logic [1:0] f_quality;
    logic [7:0] input_address, quant_address, replay_address;
    logic replay_issue_done, replay_valid, residual_valid;
    logic signed [15:0] residual_data;
    logic [3:0] residual_x, residual_y;
    logic residual_last, residual_pair_last, output_pair_last;

    logic f_command_ready, f_s_ready, f_m_valid, f_m_ready;
    logic signed [15:0] f_m_data;
    logic [3:0] f_m_x, f_m_y;
    logic f_m_plane, f_m_last, f_m_pair_last;
    logic i_command_ready, i_s_ready, i_m_valid, i_m_ready;
    logic signed [15:0] i_m_data;
    logic [3:0] i_m_x, i_m_y;
    logic i_m_plane, i_m_last, i_m_pair_last;
    logic f_done, f_busy, i_done, i_busy;
    logic quant_s_ready, quant_m_valid, quant_m_ready;
    logic signed [15:0] quantized, dequantized;
    logic quant_nonzero, quant_qp_error;
    logic [3:0] quant_x, quant_y;
    logic quant_last;
    logic [5:0] luma_qp, chroma_qp;
    logic [3:0] luma_qp_per, chroma_qp_per, selected_qp_per;
    logic [2:0] luma_qp_rem, chroma_qp_rem, selected_qp_rem;
    logic profile_valid, chroma_qp_error;

    logic pred0_we, pred1_we, pred2_we, pred3_we;
    logic pred0_re, pred1_re, pred2_re, pred3_re;
    logic [7:0] pred0_rd, pred1_rd, pred2_rd, pred3_rd;
    logic [7:0] prediction_read_data;
    logic deq0_we, deq1_we, deq2_we, deq3_we;
    logic deq0_re, deq1_re, deq2_re, deq3_re;
    logic signed [15:0] deq0_rd, deq1_rd, deq2_rd, deq3_rd;
    logic signed [15:0] dequant_read_data;
    logic reconstruct_s_ready, reconstruct_m_valid;
    logic [7:0] reconstruct_pixel;

    wire command_fire = command_valid && command_ready;
    wire source_fire = s_valid && s_ready;
    wire coefficient_fire = coefficient_valid && coefficient_ready;
    wire replay_ready = !replay_valid || i_s_ready;
    wire replay_issue = (istate == I_REPLAY) && !replay_issue_done && replay_ready;
    wire replay_fire = replay_valid && i_s_ready;
    wire prediction_ready = !residual_valid || reconstruct_s_ready;
    wire inverse_output_fire = i_m_valid && i_m_ready;
    wire reconstruct_input_fire = residual_valid && reconstruct_s_ready;
    wire output_fire = m_valid && m_ready;
    wire forward_quant_active = (fstate == F_LOAD) || (fstate == F_QUANT);
    wire inverse_reconstruct_active =
        (istate == I_REPLAY) || (istate == I_RECON);
    wire [7:0] f_final = f_pair8 ? 8'd127 : (f_size8 ? 8'd63 : 8'd255);
    wire [7:0] i_final = i_pair8 ? 8'd127 : (i_size8 ? 8'd63 : 8'd255);

    function automatic logic [1:0] next_bank(input logic [1:0] bank);
        next_bank = (bank == 3) ? 0 : bank + 1'b1;
    endfunction

    function automatic logic [7:0] raster_address(
        input logic size8, input logic pair8, input logic plane,
        input logic [3:0] x, input logic [3:0] y);
        raster_address = size8 ? {1'b0, pair8 && plane, y[2:0], x[2:0]} :
            {y, x};
    endfunction

    function automatic logic [7:0] column_major_address(
        input logic size8, input logic pair8, input logic [7:0] index);
        column_major_address = size8
            ? {1'b0, pair8 && index[6], index[2:0], index[5:3]}
            : {index[3:0], index[7:4]};
    endfunction

    assign command_ready = (fstate == F_IDLE) &&
                           (bank_state[write_bank] == BANK_FREE);
    assign s_ready = (fstate == F_LOAD) && f_s_ready;
    assign busy = (fstate != F_IDLE) || (istate != I_IDLE) ||
                  (bank_state[0] != BANK_FREE) ||
                  (bank_state[1] != BANK_FREE) ||
                  (bank_state[2] != BANK_FREE) ||
                  (bank_state[3] != BANK_FREE);

    hevc_shared_transform_fabric16 forward_transform (
        .clk, .rst_n, .command_valid(fstate == F_COMMAND),
        .command_ready(f_command_ready), .command_pair8(f_pair8),
        .command_inverse(1'b0), .s_valid((fstate == F_LOAD) && s_valid),
        .s_ready(f_s_ready), .s_data({{7{s_residual[8]}}, s_residual}),
        .m_valid(f_m_valid), .m_ready(f_m_ready), .m_data(f_m_data),
        .m_plane(f_m_plane), .m_x(f_m_x), .m_y(f_m_y),
        .m_block_last(f_m_last), .m_pair_last(f_m_pair_last),
        .done(f_done), .busy(f_busy));
    assign f_m_ready = forward_quant_active && quant_s_ready;

    hevc_qp_profile profile (
        .quality(f_quality), .qp(luma_qp), .qp_per(luma_qp_per),
        .qp_rem(luma_qp_rem), .profile_valid
    );
    hevc_chroma_qp chroma_map (
        .luma_qp, .chroma_qp, .qp_per(chroma_qp_per),
        .qp_rem(chroma_qp_rem), .qp_error(chroma_qp_error)
    );
    always_comb begin
        selected_qp_per = f_chroma ? chroma_qp_per : luma_qp_per;
        selected_qp_rem = f_chroma ? chroma_qp_rem : luma_qp_rem;
    end
    hevc_shared_quant_dequant quant (
        .clk, .rst_n, .s_valid(forward_quant_active && f_m_valid),
        .s_ready(quant_s_ready), .s_size8(f_size8),
        .s_coefficient(f_m_data), .s_qp_per(selected_qp_per),
        .s_qp_rem(selected_qp_rem), .s_x(f_m_x), .s_y(f_m_y),
        .s_block_last(f_m_last), .m_valid(quant_m_valid),
        .m_ready(quant_m_ready), .m_quantized(quantized),
        .m_dequantized(dequantized), .m_nonzero(quant_nonzero),
        .m_qp_error(quant_qp_error), .m_x(quant_x), .m_y(quant_y),
        .m_block_last(quant_last)
    );
    assign coefficient_valid = forward_quant_active && quant_m_valid;
    assign quant_m_ready = forward_quant_active && coefficient_ready;
    assign coefficient_data = quantized;
    assign coefficient_x = quant_x;
    assign coefficient_y = quant_y;
    assign coefficient_nonzero = quant_nonzero;
    assign coefficient_block_last = quant_last;

    always_comb begin
        case (inverse_bank)
            2'd1: dequant_read_data = deq1_rd;
            2'd2: dequant_read_data = deq2_rd;
            2'd3: dequant_read_data = deq3_rd;
            default: dequant_read_data = deq0_rd;
        endcase
    end
    hevc_shared_transform_fabric16 inverse_transform (
        .clk, .rst_n, .command_valid(istate == I_COMMAND),
        .command_ready(i_command_ready), .command_pair8(i_pair8),
        .command_inverse(1'b1), .s_valid((istate == I_REPLAY) && replay_valid),
        .s_ready(i_s_ready), .s_data(dequant_read_data),
        .m_valid(i_m_valid), .m_ready(i_m_ready), .m_data(i_m_data),
        .m_plane(i_m_plane), .m_x(i_m_x), .m_y(i_m_y),
        .m_block_last(i_m_last), .m_pair_last(i_m_pair_last),
        .done(i_done), .busy(i_busy));
    assign i_m_ready = inverse_reconstruct_active && prediction_ready;

    assign pred0_we = source_fire && (forward_bank == 0);
    assign pred1_we = source_fire && (forward_bank == 1);
    assign pred2_we = source_fire && (forward_bank == 2);
    assign pred3_we = source_fire && (forward_bank == 3);
    assign pred0_re = inverse_output_fire && (inverse_bank == 0);
    assign pred1_re = inverse_output_fire && (inverse_bank == 1);
    assign pred2_re = inverse_output_fire && (inverse_bank == 2);
    assign pred3_re = inverse_output_fire && (inverse_bank == 3);
    always_comb begin
        case (inverse_bank)
            2'd1: prediction_read_data = pred1_rd;
            2'd2: prediction_read_data = pred2_rd;
            2'd3: prediction_read_data = pred3_rd;
            default: prediction_read_data = pred0_rd;
        endcase
    end
    hevc_prediction_buffer16 pred_bank0 (
        .clk, .write_enable(pred0_we), .write_address(input_address),
        .write_data(s_prediction), .read_enable(pred0_re),
        .read_address(raster_address(i_size8, i_pair8, i_m_plane, i_m_x, i_m_y)),
        .read_data(pred0_rd));
    hevc_prediction_buffer16 pred_bank1 (
        .clk, .write_enable(pred1_we), .write_address(input_address),
        .write_data(s_prediction), .read_enable(pred1_re),
        .read_address(raster_address(i_size8, i_pair8, i_m_plane, i_m_x, i_m_y)),
        .read_data(pred1_rd));
    hevc_prediction_buffer16 pred_bank2 (
        .clk, .write_enable(pred2_we), .write_address(input_address),
        .write_data(s_prediction), .read_enable(pred2_re),
        .read_address(raster_address(i_size8, i_pair8, i_m_plane, i_m_x, i_m_y)),
        .read_data(pred2_rd));
    hevc_prediction_buffer16 pred_bank3 (
        .clk, .write_enable(pred3_we), .write_address(input_address),
        .write_data(s_prediction), .read_enable(pred3_re),
        .read_address(raster_address(i_size8, i_pair8, i_m_plane, i_m_x, i_m_y)),
        .read_data(pred3_rd));

    assign deq0_we = coefficient_fire && (forward_bank == 0);
    assign deq1_we = coefficient_fire && (forward_bank == 1);
    assign deq2_we = coefficient_fire && (forward_bank == 2);
    assign deq3_we = coefficient_fire && (forward_bank == 3);
    assign deq0_re = replay_issue && (inverse_bank == 0);
    assign deq1_re = replay_issue && (inverse_bank == 1);
    assign deq2_re = replay_issue && (inverse_bank == 2);
    assign deq3_re = replay_issue && (inverse_bank == 3);
    hevc_coefficient_buffer16 deq_bank0 (
        .clk, .write_enable(deq0_we),
        .write_address(quant_address),
        .write_data(dequantized), .read_enable(deq0_re),
        .read_address(column_major_address(i_size8, i_pair8, replay_address)),
        .read_data(deq0_rd));
    hevc_coefficient_buffer16 deq_bank1 (
        .clk, .write_enable(deq1_we),
        .write_address(quant_address),
        .write_data(dequantized), .read_enable(deq1_re),
        .read_address(column_major_address(i_size8, i_pair8, replay_address)),
        .read_data(deq1_rd));
    hevc_coefficient_buffer16 deq_bank2 (
        .clk, .write_enable(deq2_we),
        .write_address(quant_address),
        .write_data(dequantized), .read_enable(deq2_re),
        .read_address(column_major_address(i_size8, i_pair8, replay_address)),
        .read_data(deq2_rd));
    hevc_coefficient_buffer16 deq_bank3 (
        .clk, .write_enable(deq3_we),
        .write_address(quant_address),
        .write_data(dequantized), .read_enable(deq3_re),
        .read_address(column_major_address(i_size8, i_pair8, replay_address)),
        .read_data(deq3_rd));

    hevc_reconstruct #(.RESIDUAL_WIDTH(16)) reconstruct (
        .clk, .rst_n, .s_valid(residual_valid),
        .s_ready(reconstruct_s_ready), .s_prediction(prediction_read_data),
        .s_residual(residual_data), .m_valid(reconstruct_m_valid),
        .m_ready, .m_reconstructed(reconstruct_pixel));
    assign m_valid = reconstruct_m_valid;
    assign m_reconstructed = reconstruct_pixel;
    assign m_block_error = bank_error[inverse_bank];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            fstate <= F_IDLE; istate <= I_IDLE;
            bank_state[0] <= BANK_FREE; bank_state[1] <= BANK_FREE;
            bank_state[2] <= BANK_FREE; bank_state[3] <= BANK_FREE;
            bank_size8[0] <= 1'b0; bank_size8[1] <= 1'b0;
            bank_size8[2] <= 1'b0; bank_size8[3] <= 1'b0;
            bank_pair8[0] <= 1'b0; bank_pair8[1] <= 1'b0;
            bank_pair8[2] <= 1'b0; bank_pair8[3] <= 1'b0;
            bank_error[0] <= 1'b0; bank_error[1] <= 1'b0;
            bank_error[2] <= 1'b0; bank_error[3] <= 1'b0;
            write_bank <= 2'd0; read_bank <= 2'd0;
            forward_bank <= 2'd0; inverse_bank <= 2'd0;
            f_size8 <= 1'b0; f_pair8 <= 1'b0;
            f_chroma <= 1'b0; f_quality <= 2'd1;
            i_size8 <= 1'b0; i_pair8 <= 1'b0;
            input_address <= '0; quant_address <= '0; replay_address <= '0;
            replay_issue_done <= 1'b0; replay_valid <= 1'b0;
            residual_valid <= 1'b0; residual_data <= '0;
            residual_x <= '0; residual_y <= '0; residual_last <= 1'b0;
            residual_pair_last <= 1'b0; output_pair_last <= 1'b0;
            m_x <= '0; m_y <= '0; m_block_last <= 1'b0; done <= 1'b0;
        end else begin
            done <= 1'b0;
            if (command_fire) begin
                forward_bank <= write_bank;
                bank_state[write_bank] <= BANK_FORWARD;
                bank_size8[write_bank] <= command_size8;
                bank_pair8[write_bank] <= command_size8 && command_chroma;
                bank_error[write_bank] <= command_quality == 2'd3;
                f_size8 <= command_size8;
                f_pair8 <= command_size8 && command_chroma;
                f_chroma <= command_chroma;
                f_quality <= command_quality;
                input_address <= '0; quant_address <= '0;
                write_bank <= next_bank(write_bank); fstate <= F_COMMAND;
            end
            if ((fstate == F_COMMAND) && f_command_ready) fstate <= F_LOAD;
            if (source_fire) begin
                if (input_address == f_final) begin
                    input_address <= '0; fstate <= F_QUANT;
                end else input_address <= input_address + 1'b1;
            end
            if (coefficient_fire) begin
                if (quant_qp_error || !profile_valid ||
                        (f_chroma && chroma_qp_error))
                    bank_error[forward_bank] <= 1'b1;
                if (quant_address == f_final) begin
                    bank_state[forward_bank] <= BANK_READY;
                    fstate <= F_IDLE;
                    quant_address <= '0;
                end else quant_address <= quant_address + 1'b1;
            end

            if ((istate == I_IDLE) && (bank_state[read_bank] == BANK_READY)) begin
                inverse_bank <= read_bank;
                i_size8 <= bank_size8[read_bank];
                i_pair8 <= bank_pair8[read_bank];
                bank_state[read_bank] <= BANK_INVERSE;
                istate <= I_COMMAND;
            end
            if ((istate == I_COMMAND) && i_command_ready) begin
                replay_address <= '0; replay_issue_done <= 1'b0;
                replay_valid <= 1'b0; istate <= I_REPLAY;
            end
            if ((istate == I_REPLAY) && replay_ready) begin
                replay_valid <= replay_issue;
                if (replay_issue) begin
                    if (replay_address == i_final) replay_issue_done <= 1'b1;
                    else replay_address <= replay_address + 1'b1;
                end
            end
            if (replay_fire && replay_issue_done) begin
                istate <= I_RECON;
            end
            if (inverse_reconstruct_active && prediction_ready) begin
                residual_valid <= inverse_output_fire;
                if (inverse_output_fire) begin
                    residual_data <= i_m_data; residual_x <= i_m_x;
                    residual_y <= i_m_y; residual_last <= i_m_last;
                    residual_pair_last <= i_m_pair_last;
                end
            end
            if (reconstruct_input_fire) begin
                m_x <= residual_x; m_y <= residual_y;
                m_block_last <= residual_last;
                output_pair_last <= residual_pair_last;
            end
            if (output_fire && m_block_last && (!i_pair8 || output_pair_last)) begin
                bank_state[inverse_bank] <= BANK_FREE;
                read_bank <= next_bank(read_bank); istate <= I_IDLE; done <= 1'b1;
            end
        end
    end

    logic unused_status;
    assign unused_status = ^{f_done, f_busy, i_done, i_busy, chroma_qp,
        f_m_plane, f_m_pair_last, quant_last};
endmodule
