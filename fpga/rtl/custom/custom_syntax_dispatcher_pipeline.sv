module custom_syntax_dispatcher_pipeline #(
    parameter integer TOKEN_WIDTH = 32
) (
    input  logic                       clk,
    input  logic                       rst_n,
    input  logic                       clear_error,

    input  logic                       s_valid,
    output logic                       s_ready,
    input  logic [1:0]                 s_op_type,
    input  logic                       s_layer,
    input  logic                       s_mandatory,
    input  logic [5:0]                 s_reserve_release,
    input  logic                       s_table_class,
    input  logic                       s_table_id,
    input  logic [7:0]                 s_symbol,
    input  logic [10:0]                s_amplitude,
    input  logic [3:0]                 s_amplitude_length,
    input  logic                       s_raw_value,
    input  logic [1:0]                 s_raw_length,
    input  logic                       s_eob_required,

    output logic                       m_valid,
    input  logic                       m_ready,
    output logic                       m_layer,
    output logic [TOKEN_WIDTH-1:0]     m_bits,
    output logic [5:0]                 m_length,
    output logic                       m_mandatory,
    output logic [5:0]                 m_reserve_release,

    output logic                       input_error,
    output logic                       busy
);
    localparam logic [1:0] OP_RAW = 2'd0;
    localparam logic [1:0] OP_VLC = 2'd1;
    localparam logic [1:0] OP_SEGMENT_END = 2'd2;
    localparam logic [5:0] MAX_TOKEN_BITS = 6'(TOKEN_WIDTH);

    logic pipeline_advance;
    logic input_fire;
    logic input_needs_vlc;
    logic rom_read_enable;
    logic [21:0] rom_data;

    logic stage0_valid;
    logic [1:0] stage0_op_type;
    logic stage0_layer, stage0_mandatory, stage0_needs_vlc;
    logic [5:0] stage0_reserve_release;
    logic stage0_table_class;
    logic [7:0] stage0_symbol;
    logic [10:0] stage0_amplitude;
    logic [3:0] stage0_amplitude_length;
    logic stage0_raw_value;
    logic [1:0] stage0_raw_length;

    logic stage1_valid;
    logic stage1_layer, stage1_mandatory;
    logic [TOKEN_WIDTH-1:0] stage1_bits;
    logic [5:0] stage1_length, stage1_reserve_release;

    logic stage0_syntax_valid;
    logic [4:0] rom_huffman_length;
    logic [15:0] rom_huffman_code;
    logic [10:0] amplitude_mask;
    logic [31:0] combined_right;
    logic [5:0] combined_length;

    assign pipeline_advance = !m_valid || m_ready;
    assign s_ready = pipeline_advance;
    assign input_fire = s_valid && s_ready;
    assign input_needs_vlc = (s_op_type == OP_VLC)
                          || ((s_op_type == OP_SEGMENT_END)
                              && s_eob_required);
    assign rom_read_enable = input_fire && input_needs_vlc;
    assign busy = stage0_valid || stage1_valid || m_valid;

    assign rom_huffman_length = rom_data[20:16];
    assign rom_huffman_code = rom_data[15:0];
    assign amplitude_mask =
        11'h7ff >> (4'd11 - stage0_amplitude_length);
    assign combined_right =
        ({16'b0, rom_huffman_code} << stage0_amplitude_length)
        | {{21{1'b0}}, (stage0_amplitude & amplitude_mask)};
    assign combined_length =
        {1'b0, rom_huffman_length}
        + {2'b0, stage0_amplitude_length};

    always_comb begin
        stage0_syntax_valid = 1'b0;
        if (!stage0_table_class) begin
            stage0_syntax_valid = (stage0_symbol[7:4] == 0)
                && (stage0_symbol[3:0] <= 11)
                && (stage0_amplitude_length == stage0_symbol[3:0]);
        end else if ((stage0_symbol == 8'h00)
                || (stage0_symbol == 8'hf0)) begin
            stage0_syntax_valid = stage0_amplitude_length == 0;
        end else begin
            stage0_syntax_valid = (stage0_symbol[3:0] != 0)
                && (stage0_symbol[3:0] <= 10)
                && (stage0_amplitude_length == stage0_symbol[3:0]);
        end
    end

    custom_vlc_rom table_rom (
        .clk(clk),
        .read_enable(rom_read_enable),
        .table_class((s_op_type == OP_SEGMENT_END)
                     ? 1'b1 : s_table_class),
        .table_id(s_table_id),
        .symbol((s_op_type == OP_SEGMENT_END) ? 8'h00 : s_symbol),
        .read_data(rom_data)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stage0_valid <= 1'b0;
            stage0_op_type <= OP_RAW;
            stage0_layer <= 1'b0;
            stage0_mandatory <= 1'b0;
            stage0_needs_vlc <= 1'b0;
            stage0_reserve_release <= 0;
            stage0_table_class <= 1'b0;
            stage0_symbol <= 0;
            stage0_amplitude <= 0;
            stage0_amplitude_length <= 0;
            stage0_raw_value <= 1'b0;
            stage0_raw_length <= 0;
            stage1_valid <= 1'b0;
            stage1_layer <= 1'b0;
            stage1_mandatory <= 1'b0;
            stage1_bits <= '0;
            stage1_length <= 0;
            stage1_reserve_release <= 0;
            m_valid <= 1'b0;
            m_layer <= 1'b0;
            m_bits <= '0;
            m_length <= 0;
            m_mandatory <= 1'b0;
            m_reserve_release <= 0;
            input_error <= 1'b0;
        end else begin
            if (clear_error)
                input_error <= 1'b0;

            if (pipeline_advance) begin
                m_valid <= stage1_valid;
                if (stage1_valid) begin
                    m_layer <= stage1_layer;
                    m_bits <= stage1_bits;
                    m_length <= stage1_length;
                    m_mandatory <= stage1_mandatory;
                    m_reserve_release <= stage1_reserve_release;
                end

                stage1_valid <= stage0_valid;
                if (stage0_valid) begin
                    stage1_layer <= stage0_layer;
                    stage1_mandatory <= stage0_mandatory;
                    stage1_reserve_release <= stage0_reserve_release;
                    if (stage0_needs_vlc) begin
                        if (rom_data[21] && stage0_syntax_valid
                                && (combined_length <= MAX_TOKEN_BITS)) begin
                            stage1_bits <= combined_right
                                << (MAX_TOKEN_BITS - combined_length);
                            stage1_length <= combined_length;
                        end else begin
                            stage1_valid <= 1'b0;
                            input_error <= 1'b1;
                        end
                    end else if (stage0_op_type == OP_RAW) begin
                        if (stage0_raw_length == 1) begin
                            stage1_bits <=
                                {{(TOKEN_WIDTH-1){1'b0}},
                                 stage0_raw_value}
                                << (TOKEN_WIDTH - 1);
                            stage1_length <= 1;
                        end else begin
                            stage1_valid <= 1'b0;
                            input_error <= 1'b1;
                        end
                    end else if (stage0_op_type == OP_SEGMENT_END) begin
                        stage1_bits <= '0;
                        stage1_length <= 0;
                    end else begin
                        stage1_valid <= 1'b0;
                        input_error <= 1'b1;
                    end
                end

                stage0_valid <= input_fire;
                if (input_fire) begin
                    stage0_op_type <= s_op_type;
                    stage0_layer <= s_layer;
                    stage0_mandatory <= s_mandatory;
                    stage0_needs_vlc <= input_needs_vlc;
                    stage0_reserve_release <= s_reserve_release;
                    stage0_table_class <= (s_op_type == OP_SEGMENT_END)
                        ? 1'b1 : s_table_class;
                    stage0_symbol <= (s_op_type == OP_SEGMENT_END)
                        ? 8'h00 : s_symbol;
                    stage0_amplitude <= (s_op_type == OP_SEGMENT_END)
                        ? 11'd0 : s_amplitude;
                    stage0_amplitude_length <=
                        (s_op_type == OP_SEGMENT_END)
                        ? 4'd0 : s_amplitude_length;
                    stage0_raw_value <= s_raw_value;
                    stage0_raw_length <= s_raw_length;
                end
            end
        end
    end
endmodule
