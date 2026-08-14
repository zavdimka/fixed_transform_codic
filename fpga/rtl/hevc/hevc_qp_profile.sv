module hevc_qp_profile #(
    parameter integer QP_GOOD   = 28,
    parameter integer QP_MEDIUM = 34,
    parameter integer QP_POOR   = 40
) (
    input  logic [1:0] quality,
    output logic [5:0] qp,
    output logic [3:0] qp_per,
    output logic [2:0] qp_rem,
    output logic       profile_valid
);
    always_comb begin
        profile_valid = 1'b1;
        case (quality)
            2'd0: begin
                qp = 6'(QP_GOOD);
                qp_per = 4'(QP_GOOD / 6);
                qp_rem = 3'(QP_GOOD % 6);
            end
            2'd1: begin
                qp = 6'(QP_MEDIUM);
                qp_per = 4'(QP_MEDIUM / 6);
                qp_rem = 3'(QP_MEDIUM % 6);
            end
            2'd2: begin
                qp = 6'(QP_POOR);
                qp_per = 4'(QP_POOR / 6);
                qp_rem = 3'(QP_POOR % 6);
            end
            default: begin
                qp = 6'(QP_MEDIUM);
                qp_per = 4'(QP_MEDIUM / 6);
                qp_rem = 3'(QP_MEDIUM % 6);
                profile_valid = 1'b0;
            end
        endcase
    end

    initial begin
        if ((QP_GOOD < 0) || (QP_GOOD > 51) ||
            (QP_MEDIUM < 0) || (QP_MEDIUM > 51) ||
            (QP_POOR < 0) || (QP_POOR > 51)) begin
            $error("HEVC quality profile QPs must be in [0, 51]");
        end
    end
endmodule
