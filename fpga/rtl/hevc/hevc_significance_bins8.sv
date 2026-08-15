module hevc_significance_bins8 (
    input logic clk, input logic rst_n,
    input logic s_valid, output logic s_ready,
    input logic [5:0] s_raster_address, input logic [5:0] s_scan_position,
    input logic signed [15:0] s_coefficient,
    input logic s_group_nonzero, input logic [3:0] s_significant_group_flags,
    input logic s_block_last,
    output logic m_valid, input logic m_ready, output logic m_bin,
    output logic m_coded_sub_block, output logic [3:0] m_context_index,
    output logic [5:0] m_scan_position, output logic m_syntax_last,
    output logic stage_done, output logic busy, output logic input_error
);
    typedef enum logic [1:0] {START, COEFFICIENT, GROUP_FLAG} state_t;
    state_t state;
    logic [1:0] current_group, last_group;
    logic [4:0] nonzero_in_group;
    logic [3:0] group_flags;

    function automatic logic [1:0] diagonal2(input logic [1:0] i);
        case (i) 0:diagonal2=0;1:diagonal2=2;2:diagonal2=1;default:diagonal2=3; endcase
    endfunction
    function automatic logic group_context(input logic [3:0] flags, input logic [1:0] gr);
        logic right, lower;
        begin
            right = !gr[0] && flags[gr + 1'b1];
            lower = !gr[1] && flags[gr + 2'd2];
            group_context = right || lower;
        end
    endfunction
    function automatic logic [3:0] coefficient_context(
        input logic [3:0] flags, input logic [5:0] address
    );
        logic [2:0] x, y; logic [1:0] gr; logic right, lower;
        logic [1:0] pattern, lx, ly, count; logic [2:0] sum;
        begin
            x=address[2:0]; y=address[5:3];
            if (x+y==0) coefficient_context=0;
            else begin
                gr={y[2],x[2]};
                right=!x[2] && flags[gr+1'b1];
                lower=!y[2] && flags[gr+2'd2];
                pattern={lower,right}; lx=x[1:0]; ly=y[1:0]; sum=lx+ly;
                case (pattern)
                    0: count=(sum==0)?2:((sum<=2)?1:0);
                    1: count=(ly==0)?2:((ly==1)?1:0);
                    2: count=(lx==0)?2:((lx==1)?1:0);
                    default: count=2;
                endcase
                coefficient_context=4'd12+{2'd0,count};
            end
        end
    endfunction

    wire [1:0] input_group=s_scan_position[5:4];
    wire [1:0] input_group_raster=diagonal2(input_group);
    wire coefficient_nonzero=s_coefficient!=0;
    wire group_active=(current_group==last_group)||(current_group==0)||s_group_nonzero;
    wire coefficient_required=(s_scan_position[3:0]!=0)||(current_group==0)||(nonzero_in_group!=0);
    wire group_flag_required=input_group!=0;

    always_comb begin
        s_ready=0;m_valid=0;m_bin=0;m_coded_sub_block=0;m_context_index=0;
        m_scan_position=s_scan_position;m_syntax_last=0;busy=state!=START;
        case(state)
            START:s_ready=1;
            COEFFICIENT:if(s_valid&&input_group==current_group)begin
                if(group_active&&coefficient_required)begin
                    m_valid=1;s_ready=m_ready;m_bin=coefficient_nonzero;
                    m_context_index=coefficient_context(group_flags,s_raster_address);
                    m_syntax_last=s_block_last;
                end else s_ready=1;
            end
            default:if(s_valid&&group_flag_required)begin
                m_valid=1;m_bin=s_group_nonzero;m_coded_sub_block=1;
                m_context_index={3'd0,group_context(group_flags,input_group_raster)};
                m_scan_position={input_group,4'hf};
            end
        endcase
    end

    always_ff @(posedge clk) begin
        if(!rst_n)begin state<=START;current_group<=0;last_group<=0;
            nonzero_in_group<=0;group_flags<=0;stage_done<=0;input_error<=0;end
        else begin
            stage_done<=0;
            case(state)
                START:if(s_valid)begin
                    current_group<=input_group;last_group<=input_group;
                    nonzero_in_group<=coefficient_nonzero?1:0;
                    group_flags<=s_significant_group_flags;input_error<=!coefficient_nonzero;
                    if(s_block_last)stage_done<=1;else state<=COEFFICIENT;
                end
                COEFFICIENT:begin
                    if(s_valid&&input_group!=current_group)state<=GROUP_FLAG;
                    else if(s_valid&&s_ready)begin
                        if(coefficient_nonzero)nonzero_in_group<=nonzero_in_group+1'b1;
                        if(group_active&&!coefficient_required&&!coefficient_nonzero)input_error<=1;
                        if(s_block_last)begin stage_done<=1;state<=START;end
                    end
                end
                default:begin
                    if(s_valid&&!group_flag_required)begin
                        current_group<=input_group;nonzero_in_group<=0;state<=COEFFICIENT;
                    end else if(m_valid&&m_ready)begin
                        current_group<=input_group;nonzero_in_group<=0;state<=COEFFICIENT;
                    end
                end
            endcase
        end
    end
endmodule
