module hevc_intra_frontend16 (
    input  logic              clk,
    input  logic              rst_n,

    input  logic              start_valid,
    output logic              start_ready,

    input  logic              ref_valid,
    output logic              ref_ready,
    input  logic [7:0]        ref_top,
    input  logic [7:0]        ref_left,
    input  logic              ref_last,

    input  logic              s_valid,
    output logic              s_ready,
    input  logic [7:0]        s_pixel,

    output logic              m_valid,
    input  logic              m_ready,
    output logic [7:0]        m_prediction,
    output logic signed [8:0] m_residual,
    output logic              m_luma_mode_dc,
    output logic              m_block_last,

    output logic [16:0]       dc_sad,
    output logic [16:0]       planar_sad,
    output logic              done,
    output logic              protocol_error,
    output logic              busy
);
    typedef enum logic [2:0] {
        IDLE,
        LOAD_REFERENCES,
        ANALYZE_PIXELS,
        WAIT_MODE,
        RELOAD_REFERENCES,
        REPLAY_PIXELS
    } state_t;

    state_t state;
    logic [7:0] top_references [0:18];
    logic [7:0] left_references [0:18];
    logic [4:0] reference_index;
    logic [7:0] input_address;
    logic [8:0] replay_reads_issued;
    logic replay_pixel_valid;
    logic selected_planar;

    logic source_write_enable;
    logic source_read_enable;
    logic [7:0] source_read_address;
    logic [7:0] source_read_data;

    logic dc_ref_valid;
    logic dc_ref_ready;
    logic [7:0] dc_ref_top;
    logic [7:0] dc_ref_left;
    logic dc_s_valid;
    logic dc_s_ready;
    logic [7:0] dc_s_pixel;
    logic dc_m_valid;
    logic dc_m_ready;
    logic [7:0] dc_prediction;
    logic signed [8:0] dc_residual;
    logic dc_block_last;

    logic planar_ref_valid;
    logic planar_ref_ready;
    logic [7:0] planar_ref_top;
    logic [7:0] planar_ref_left;
    logic planar_s_valid;
    logic planar_s_ready;
    logic [7:0] planar_s_pixel;
    logic planar_m_valid;
    logic planar_m_ready;
    logic [7:0] planar_prediction;
    logic signed [8:0] planar_residual;
    logic planar_block_last;

    logic sad_s_valid;
    logic sad_s_ready;
    logic sad_m_valid;
    logic sad_m_ready;
    logic sad_planar_selected;
    logic [16:0] sad_dc;
    logic [16:0] sad_planar;

    wire external_reference_phase = state == LOAD_REFERENCES;
    wire reload_reference_phase = state == RELOAD_REFERENCES;
    wire reference_phase = external_reference_phase || reload_reference_phase;
    wire dc_reference_index = (reference_index >= 1) &&
        (reference_index <= 16);
    wire reference_sources_ready = planar_ref_ready &&
        (!dc_reference_index || dc_ref_ready);
    wire reference_input_valid = external_reference_phase ? ref_valid : 1'b1;
    wire reference_fire = reference_phase && reference_input_valid &&
        reference_sources_ready;
    wire [7:0] active_ref_top = external_reference_phase ?
        ref_top : top_references[reference_index];
    wire [7:0] active_ref_left = external_reference_phase ?
        ref_left : left_references[reference_index];

    wire analyze_sources_ready = dc_s_ready && planar_s_ready;
    wire analyze_fire = (state == ANALYZE_PIXELS) && s_valid &&
        analyze_sources_ready;
    wire analysis_pair_fire = sad_s_valid && sad_s_ready;

    wire replay_pair_ready = dc_s_ready && planar_s_ready;
    wire replay_source_fire = (state == REPLAY_PIXELS) &&
        replay_pixel_valid && replay_pair_ready;
    wire replay_output_fire = m_valid && m_ready;
    wire replay_can_issue = (state == REPLAY_PIXELS) &&
        (replay_reads_issued < 9'd256) &&
        (!replay_pixel_valid || replay_source_fire);

    assign start_ready = state == IDLE;
    assign ref_ready = external_reference_phase && reference_sources_ready;
    assign s_ready = (state == ANALYZE_PIXELS) && analyze_sources_ready;
    assign busy = state != IDLE;

    assign planar_ref_valid = reference_phase && reference_input_valid &&
        (!dc_reference_index || dc_ref_ready);
    assign planar_ref_top = active_ref_top;
    assign planar_ref_left = active_ref_left;
    assign dc_ref_valid = reference_phase && reference_input_valid &&
        dc_reference_index && planar_ref_ready;
    assign dc_ref_top = active_ref_top;
    assign dc_ref_left = active_ref_left;

    assign dc_s_valid = ((state == ANALYZE_PIXELS) && s_valid &&
                         planar_s_ready) ||
                        ((state == REPLAY_PIXELS) && replay_pixel_valid &&
                         planar_s_ready);
    assign planar_s_valid = ((state == ANALYZE_PIXELS) && s_valid &&
                             dc_s_ready) ||
                            ((state == REPLAY_PIXELS) && replay_pixel_valid &&
                             dc_s_ready);
    assign dc_s_pixel = (state == REPLAY_PIXELS) ? source_read_data : s_pixel;
    assign planar_s_pixel = dc_s_pixel;

    assign sad_s_valid = (state == ANALYZE_PIXELS) &&
        dc_m_valid && planar_m_valid;
    assign dc_m_ready = (state == ANALYZE_PIXELS) ?
        (sad_s_ready && planar_m_valid) :
        ((state == REPLAY_PIXELS) && m_ready && planar_m_valid);
    assign planar_m_ready = (state == ANALYZE_PIXELS) ?
        (sad_s_ready && dc_m_valid) :
        ((state == REPLAY_PIXELS) && m_ready && dc_m_valid);
    assign sad_m_ready = state == WAIT_MODE;

    assign m_valid = (state == REPLAY_PIXELS) &&
        dc_m_valid && planar_m_valid;
    assign m_prediction = selected_planar ?
        planar_prediction : dc_prediction;
    assign m_residual = selected_planar ? planar_residual : dc_residual;
    assign m_luma_mode_dc = !selected_planar;
    assign m_block_last = selected_planar ?
        planar_block_last : dc_block_last;

    assign source_write_enable = analyze_fire;
    assign source_read_enable = replay_can_issue;
    assign source_read_address = replay_reads_issued[7:0];

    hevc_prediction_buffer16 source_buffer (
        .clk(clk),
        .write_enable(source_write_enable),
        .write_address(input_address),
        .write_data(s_pixel),
        .read_enable(source_read_enable),
        .read_address(source_read_address),
        .read_data(source_read_data)
    );

    hevc_intra_dc16 dc_predictor (
        .clk(clk),
        .rst_n(rst_n),
        .ref_valid(dc_ref_valid),
        .ref_ready(dc_ref_ready),
        .ref_top(dc_ref_top),
        .ref_left(dc_ref_left),
        .s_valid(dc_s_valid),
        .s_ready(dc_s_ready),
        .s_pixel(dc_s_pixel),
        .m_valid(dc_m_valid),
        .m_ready(dc_m_ready),
        .m_prediction(dc_prediction),
        .m_residual(dc_residual),
        .m_block_last(dc_block_last)
    );

    hevc_intra_planar16 planar_predictor (
        .clk(clk),
        .rst_n(rst_n),
        .ref_valid(planar_ref_valid),
        .ref_ready(planar_ref_ready),
        .ref_top(planar_ref_top),
        .ref_left(planar_ref_left),
        .s_valid(planar_s_valid),
        .s_ready(planar_s_ready),
        .s_pixel(planar_s_pixel),
        .m_valid(planar_m_valid),
        .m_ready(planar_m_ready),
        .m_prediction(planar_prediction),
        .m_residual(planar_residual),
        .m_block_last(planar_block_last)
    );

    hevc_intra_sad_select16 mode_select (
        .clk(clk),
        .rst_n(rst_n),
        .s_valid(sad_s_valid),
        .s_ready(sad_s_ready),
        .s_dc_residual(dc_residual),
        .s_planar_residual(planar_residual),
        .s_block_last(dc_block_last),
        .m_valid(sad_m_valid),
        .m_ready(sad_m_ready),
        .m_planar_selected(sad_planar_selected),
        .m_dc_sad(sad_dc),
        .m_planar_sad(sad_planar)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            reference_index <= 5'd0;
            input_address <= 8'd0;
            replay_reads_issued <= 9'd0;
            replay_pixel_valid <= 1'b0;
            selected_planar <= 1'b0;
            dc_sad <= 17'd0;
            planar_sad <= 17'd0;
            done <= 1'b0;
            protocol_error <= 1'b0;
        end else begin
            done <= 1'b0;

            if (state == IDLE && start_valid) begin
                state <= LOAD_REFERENCES;
                reference_index <= 5'd0;
                input_address <= 8'd0;
                replay_reads_issued <= 9'd0;
                replay_pixel_valid <= 1'b0;
                protocol_error <= 1'b0;
            end

            if (reference_fire) begin
                if (external_reference_phase) begin
                    top_references[reference_index] <= ref_top;
                    left_references[reference_index] <= ref_left;
                    if (ref_last != (reference_index == 18))
                        protocol_error <= 1'b1;
                end

                if (reference_index == 18) begin
                    reference_index <= 5'd0;
                    if (external_reference_phase)
                        state <= ANALYZE_PIXELS;
                    else begin
                        state <= REPLAY_PIXELS;
                        replay_reads_issued <= 9'd0;
                        replay_pixel_valid <= 1'b0;
                    end
                end else begin
                    reference_index <= reference_index + 1'b1;
                end
            end

            if (analyze_fire) begin
                if (input_address == 8'hff)
                    input_address <= 8'd0;
                else
                    input_address <= input_address + 1'b1;
            end

            if (analysis_pair_fire && dc_block_last)
                state <= WAIT_MODE;

            if (sad_m_valid && sad_m_ready) begin
                selected_planar <= sad_planar_selected;
                dc_sad <= sad_dc;
                planar_sad <= sad_planar;
                reference_index <= 5'd0;
                state <= RELOAD_REFERENCES;
            end

            if (source_read_enable) begin
                replay_reads_issued <= replay_reads_issued + 1'b1;
                replay_pixel_valid <= 1'b1;
            end else if (replay_source_fire) begin
                replay_pixel_valid <= 1'b0;
            end

            if (replay_output_fire && m_block_last) begin
                state <= IDLE;
                replay_pixel_valid <= 1'b0;
                done <= 1'b1;
            end
        end
    end
endmodule
