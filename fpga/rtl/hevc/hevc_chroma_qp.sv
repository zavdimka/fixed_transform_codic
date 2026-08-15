module hevc_chroma_qp (
    input logic [5:0] luma_qp,
    output logic [5:0] chroma_qp,
    output logic [3:0] qp_per,
    output logic [2:0] qp_rem,
    output logic qp_error
);
    always_comb begin
        qp_error = luma_qp > 51;
        if (luma_qp < 30) chroma_qp = luma_qp;
        else if (luma_qp == 30) chroma_qp = 29;
        else if (luma_qp == 31) chroma_qp = 30;
        else if (luma_qp == 32) chroma_qp = 31;
        else if (luma_qp == 33) chroma_qp = 32;
        else if (luma_qp == 34) chroma_qp = 33;
        else if (luma_qp == 35) chroma_qp = 33;
        else if (luma_qp == 36) chroma_qp = 34;
        else if (luma_qp == 37) chroma_qp = 34;
        else if (luma_qp == 38) chroma_qp = 35;
        else if (luma_qp == 39) chroma_qp = 35;
        else if (luma_qp == 40) chroma_qp = 36;
        else if (luma_qp == 41) chroma_qp = 36;
        else if (luma_qp <= 43) chroma_qp = 37;
        else if (luma_qp <= 51) chroma_qp = luma_qp - 6;
        else chroma_qp = 45;
        if (chroma_qp < 6) begin qp_per = 0; qp_rem = chroma_qp[2:0]; end
        else if (chroma_qp < 12) begin qp_per = 1; qp_rem = 3'(chroma_qp - 6'd6); end
        else if (chroma_qp < 18) begin qp_per = 2; qp_rem = 3'(chroma_qp - 6'd12); end
        else if (chroma_qp < 24) begin qp_per = 3; qp_rem = 3'(chroma_qp - 6'd18); end
        else if (chroma_qp < 30) begin qp_per = 4; qp_rem = 3'(chroma_qp - 6'd24); end
        else if (chroma_qp < 36) begin qp_per = 5; qp_rem = 3'(chroma_qp - 6'd30); end
        else if (chroma_qp < 42) begin qp_per = 6; qp_rem = 3'(chroma_qp - 6'd36); end
        else begin qp_per = 7; qp_rem = 3'(chroma_qp - 6'd42); end
    end
endmodule
