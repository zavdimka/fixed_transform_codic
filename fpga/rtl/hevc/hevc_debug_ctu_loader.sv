module hevc_debug_ctu_loader (
    input  logic       clk,
    input  logic       rst_n,

    input  logic       load_clear,
    input  logic       load_write_valid,
    input  logic [7:0] load_write_data,
    input  logic       load_commit,
    output logic       loaded,
    output logic [8:0] load_count,
    output logic       load_error,

    input  logic       run_valid,
    output logic       run_ready,
    output logic       run_done,
    output logic       busy,

    output logic       ctu_start_valid,
    input  logic       ctu_start_ready,
    output logic       y_valid,
    input  logic       y_ready,
    output logic [7:0] y_pixel,
    output logic       cb_valid,
    input  logic       cb_ready,
    output logic [7:0] cb_pixel,
    output logic       cr_valid,
    input  logic       cr_ready,
    output logic [7:0] cr_pixel,
    input  logic       ctu_done
);
    localparam logic [8:0] CTU_BYTES = 9'd384;

    typedef enum logic [2:0] {
        IDLE,
        START_CTU,
        SEND_Y,
        SEND_CB,
        SEND_CR,
        WAIT_DONE
    } state_t;

    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    logic [7:0] memory [0:511];
    state_t state;
    logic [8:0] next_address;
    logic [7:0] read_data;
    logic       read_valid;
    logic       selected_ready;
    logic [8:0] plane_end;

    wire run_fire = run_valid && run_ready;
    wire stream_fire = read_valid && selected_ready;
    wire plane_active = (state == SEND_Y) || (state == SEND_CB) ||
        (state == SEND_CR);
    wire issue_read = plane_active && (!read_valid || selected_ready) &&
        (next_address < plane_end);

    always_comb begin
        selected_ready = 1'b0;
        plane_end = 9'd0;
        case (state)
            SEND_Y: begin
                selected_ready = y_ready;
                plane_end = 9'd256;
            end
            SEND_CB: begin
                selected_ready = cb_ready;
                plane_end = 9'd320;
            end
            SEND_CR: begin
                selected_ready = cr_ready;
                plane_end = 9'd384;
            end
            default: begin
                selected_ready = 1'b0;
                plane_end = 9'd0;
            end
        endcase
    end

    assign run_ready = loaded && (state == IDLE);
    assign busy = state != IDLE;
    assign ctu_start_valid = state == START_CTU;
    assign y_valid = (state == SEND_Y) && read_valid;
    assign cb_valid = (state == SEND_CB) && read_valid;
    assign cr_valid = (state == SEND_CR) && read_valid;
    assign y_pixel = read_data;
    assign cb_pixel = read_data;
    assign cr_pixel = read_data;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            loaded <= 1'b0;
            load_count <= 9'd0;
            load_error <= 1'b0;
            run_done <= 1'b0;
            state <= IDLE;
            next_address <= 9'd0;
            read_data <= 8'd0;
            read_valid <= 1'b0;
        end else begin
            run_done <= 1'b0;

            if (load_clear && (state == IDLE)) begin
                loaded <= 1'b0;
                load_count <= 9'd0;
                load_error <= 1'b0;
            end

            if (load_write_valid && (state == IDLE)) begin
                if (!loaded && (load_count < CTU_BYTES)) begin
                    memory[load_count] <= load_write_data;
                    load_count <= load_count + 1'b1;
                end else begin
                    load_error <= 1'b1;
                end
            end

            if (load_commit && (state == IDLE)) begin
                loaded <= load_count == CTU_BYTES;
                if (load_count != CTU_BYTES)
                    load_error <= 1'b1;
            end

            if (run_fire) begin
                loaded <= 1'b0;
                load_count <= 9'd0;
                state <= START_CTU;
                read_valid <= 1'b0;
                next_address <= 9'd0;
            end

            if ((state == START_CTU) && ctu_start_ready) begin
                state <= SEND_Y;
                next_address <= 9'd0;
                read_valid <= 1'b0;
            end

            if (issue_read) begin
                read_data <= memory[next_address];
                next_address <= next_address + 1'b1;
                read_valid <= 1'b1;
            end else if (stream_fire) begin
                read_valid <= 1'b0;
            end

            if (stream_fire && (next_address == plane_end)) begin
                read_valid <= 1'b0;
                case (state)
                    SEND_Y: begin
                        state <= SEND_CB;
                        next_address <= 9'd256;
                    end
                    SEND_CB: begin
                        state <= SEND_CR;
                        next_address <= 9'd320;
                    end
                    SEND_CR: begin
                        state <= WAIT_DONE;
                        next_address <= 9'd384;
                    end
                    default: state <= IDLE;
                endcase
            end

            if ((state == WAIT_DONE) && ctu_done) begin
                state <= IDLE;
                run_done <= 1'b1;
            end
        end
    end
endmodule
