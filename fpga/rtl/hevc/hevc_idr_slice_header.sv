module hevc_idr_slice_header #(
    parameter integer CTU_COLUMNS = 20,
    parameter integer CTU_ROWS = 12
) (
    input  logic       clk,
    input  logic       rst_n,

    input  logic       start_valid,
    output logic       start_ready,
    input  logic [5:0] slice_row,
    input  logic [5:0] qp,
    input  logic       no_output_of_prior_pics,

    output logic       m_valid,
    input  logic       m_ready,
    output logic [7:0] m_data,
    output logic       m_last,

    output logic       busy,
    output logic       done,
    output logic       parameter_error
);
    localparam integer PIC_SIZE_IN_CTBS = CTU_COLUMNS * CTU_ROWS;
    localparam integer SLICE_ADDRESS_WIDTH =
        (PIC_SIZE_IN_CTBS <= 1) ? 1 : $clog2(PIC_SIZE_IN_CTBS);
    localparam logic [5:0] CTU_ROWS_VALUE = 6'(CTU_ROWS);

    logic [31:0] built_value;
    logic [31:0] built_shifted;
    logic [2:0]  built_byte_count;
    integer built_length;
    integer signed_code_plus1;
    integer slice_address;
    integer prefix_order;
    integer exp_golomb_length;
    integer padding_bits;

    logic [31:0] shift_register;
    logic [2:0] byte_count;

    function automatic [31:0] append_bits(
        input [31:0] current,
        input [31:0] value,
        input integer count
    );
        append_bits = (current << count) | value;
    endfunction

    function automatic integer floor_log2_7(input integer value);
        integer index;
        begin
            floor_log2_7 = 0;
            for (index = 1; index < 7; index = index + 1) begin
                if (value >= (1 << index))
                    floor_log2_7 = index;
            end
        end
    endfunction

    always_comb begin
        slice_address = slice_row * CTU_COLUMNS;
        if (qp > 26)
            signed_code_plus1 = ({26'd0, qp} - 26) << 1;
        else
            signed_code_plus1 = ((26 - {26'd0, qp}) << 1) + 1'b1;
        prefix_order = floor_log2_7(signed_code_plus1);
        exp_golomb_length = (prefix_order << 1) + 1;

        built_value = 0;
        built_length = 0;
        built_value = append_bits(built_value, (slice_row == 0) ? 32'd1 : 32'd0, 1);
        built_length = built_length + 1;
        built_value = append_bits(
            built_value, no_output_of_prior_pics ? 32'd1 : 32'd0, 1
        );
        built_length = built_length + 1;
        built_value = append_bits(built_value, 1, 1); // PPS id ue(v)=0
        built_length = built_length + 1;

        if (slice_row != 0) begin
            built_value = append_bits(
                built_value, slice_address, SLICE_ADDRESS_WIDTH
            );
            built_length = built_length + SLICE_ADDRESS_WIDTH;
        end

        built_value = append_bits(built_value, 3, 3); // I slice ue(v)=2
        built_length = built_length + 3;
        built_value = append_bits(
            built_value, signed_code_plus1, exp_golomb_length
        );
        built_length = built_length + exp_golomb_length;

        // byte_alignment(): alignment_bit_equal_to_one, then zeroes.
        built_value = append_bits(built_value, 1, 1);
        built_length = built_length + 1;
        padding_bits = (-built_length) & 7;
        built_value = append_bits(built_value, 0, padding_bits);
        built_length = built_length + padding_bits;

        built_shifted = built_value << (32 - built_length);
        built_byte_count = built_length[5:3];
    end

    assign start_ready = !busy;
    assign m_valid = busy;
    assign m_data = shift_register[31:24];
    assign m_last = busy && (byte_count == 1);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            shift_register <= '0;
            byte_count <= '0;
            busy <= 1'b0;
            done <= 1'b0;
            parameter_error <= 1'b0;
        end else begin
            done <= 1'b0;
            parameter_error <= 1'b0;

            if (!busy) begin
                if (start_valid) begin
                    if ((slice_row >= CTU_ROWS_VALUE) || (qp > 51) ||
                        (built_length > 32)) begin
                        parameter_error <= 1'b1;
                    end else begin
                        shift_register <= built_shifted;
                        byte_count <= built_byte_count;
                        busy <= 1'b1;
                    end
                end
            end else if (m_ready) begin
                if (byte_count == 1) begin
                    byte_count <= 0;
                    busy <= 1'b0;
                    done <= 1'b1;
                end else begin
                    shift_register <= shift_register << 8;
                    byte_count <= byte_count - 1'b1;
                end
            end
        end
    end
endmodule
