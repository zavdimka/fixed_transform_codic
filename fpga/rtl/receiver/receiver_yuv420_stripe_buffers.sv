module receiver_yuv420_stripe_buffers (
    input  logic        write_clk,
    input  logic        write_rst_n,

    input  logic        record_valid,
    output logic        record_ready,
    input  logic [7:0]  record_type,
    input  logic [15:0] display_frame_id,
    input  logic [7:0]  stripe_id,
    input  logic [7:0]  fragment_index,
    input  logic [7:0]  fragment_count,
    input  logic [15:0] payload_length,
    input  logic [7:0]  payload_data,
    input  logic        payload_valid,
    output logic        payload_ready,
    input  logic        payload_last,

    // Direct reconstructed-sample port used by the base decoder. Addresses
    // are plane-local: 0..20479 for Y and 0..5119 for Cb/Cr.
    input  logic        decoded_write_valid,
    output logic        decoded_write_ready,
    input  logic        decoded_write_start,
    input  logic        decoded_write_last,
    input  logic [15:0] decoded_frame_id,
    input  logic [7:0]  decoded_stripe_id,
    input  logic [1:0]  decoded_plane,
    input  logic [14:0] decoded_address,
    input  logic [7:0]  decoded_data,

    input  logic        pixel_clk,
    input  logic        pixel_rst_n,
    input  logic [11:0] x,
    input  logic [9:0]  y,
    input  logic        data_enable,
    input  logic        hsync,
    input  logic        vsync,
    output logic [23:0] rgb,
    output logic        data_enable_out,
    output logic        hsync_out,
    output logic        vsync_out,

    output logic [31:0] completed_stripe_count,
    output logic [31:0] rejected_stripe_count,
    output logic [31:0] displayed_stripe_count,
    output logic [31:0] missing_stripe_count
);
    localparam logic [7:0] RAW_YUV420_RECORD = 8'h20;
    localparam logic [14:0] Y_BYTES = 15'd20480;
    localparam logic [14:0] U_END = 15'd25600;
    localparam logic [14:0] STRIPE_BYTES = 15'd30720;

    // Separate plane/bank arrays avoid address padding and infer exactly the
    // six independent dual-clock memories needed by two YUV420 stripes.
    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    logic [7:0] y_bank0 [0:20479];
    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    logic [7:0] y_bank1 [0:20479];
    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    logic [7:0] u_bank0 [0:5119];
    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    logic [7:0] u_bank1 [0:5119];
    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    logic [7:0] v_bank0 [0:5119];
    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    logic [7:0] v_bank1 [0:5119];

    logic [1:0] bank_available;
    logic free_bank_available_registered;
    logic reserve_bank_index_registered;
    logic [1:0] bank_ready_write;
    logic [1:0] bank_release_sync1, bank_release_sync2;
    logic [1:0] bank_release_seen;
    logic [15:0] bank_frame_id [0:1];
    logic [7:0] bank_stripe_id [0:1];

    logic assembly_active;
    logic assembly_bank;
    logic [15:0] assembly_frame_id;
    logic [7:0] assembly_stripe_id;
    logic [7:0] assembly_fragment_count;
    logic [7:0] expected_fragment_index;
    logic [14:0] stripe_write_offset;
    logic current_record_write;
    logic assembly_decoded;
    logic decoded_pipeline_valid;
    logic decoded_pipeline_bank;
    logic decoded_pipeline_last;
    logic [1:0] decoded_pipeline_plane;
    logic [14:0] decoded_pipeline_address;
    logic [7:0] decoded_pipeline_data;
    logic raw_pipeline_valid;
    logic raw_pipeline_bank;
    logic [1:0] raw_pipeline_plane;
    logic [14:0] raw_pipeline_y_address;
    logic [12:0] raw_pipeline_c_address;
    logic [7:0] raw_pipeline_data;

    wire free_bank_available = free_bank_available_registered;
    wire raw_first_fragment = (record_type == RAW_YUV420_RECORD)
                            && (fragment_index == 0);
    wire raw_first_blocked = record_valid && raw_first_fragment
                           && assembly_active && assembly_decoded;
    wire first_fragment_needs_bank = record_valid && raw_first_fragment
                                   && !assembly_active;
    // Raw debug records own the assembly control edge. If a reconstructed
    // sample arrives simultaneously, backpressure keeps it in the arbiter
    // instead of letting decoded_fire enter the raw offset update cone.
    wire raw_record_claim = record_valid && record_ready
                          && (record_type == RAW_YUV420_RECORD);

    // Non-raw records are drained by this checkpoint and handed to the real
    // decoder in the next one. A new raw stripe waits if both banks are owned
    // by the display side; malformed continuation records are consumed and
    // rejected instead of deadlocking the link.
    always_comb begin
        record_ready = !raw_first_blocked
                    && (!first_fragment_needs_bank || free_bank_available);
        payload_ready = 1'b1;
        // A new decoded stripe must not overlap the one-cycle RAM write
        // pipeline of the previous stripe's last sample. Waiting until
        // assembly_active clears also guarantees selection of a different
        // free bank for a back-to-back stripe.
        decoded_write_ready = (decoded_write_start
            ? (!assembly_active && free_bank_available)
            : (assembly_active && assembly_decoded))
            && !raw_record_claim;
    end

    wire payload_fire = payload_valid && payload_ready;
    wire [14:0] next_write_offset = stripe_write_offset + 1'b1;
    wire [12:0] chroma_write_address =
        (stripe_write_offset < U_END)
        ? 13'(stripe_write_offset - Y_BYTES)
        : 13'(stripe_write_offset - U_END);
    wire decoded_fire = decoded_write_valid && decoded_write_ready;
    wire decoded_target_bank = assembly_active
                             ? assembly_bank : reserve_bank_index;
    wire decoded_reserve_bank = decoded_fire && decoded_write_start
                              && !assembly_active;
    wire raw_reserve_bank = record_valid && record_ready
                          && (record_type == RAW_YUV420_RECORD)
                          && (fragment_index == 0) && !assembly_active;
    wire reserve_bank_index = reserve_bank_index_registered;
    wire [1:0] bank_release_mask = bank_release_sync2
                                 ^ bank_release_seen;
    wire [1:0] bank_clear_mask = (decoded_reserve_bank || raw_reserve_bank)
        ? (reserve_bank_index ? 2'b10 : 2'b01) : 2'b00;
    wire invalid_raw_release = payload_fire && current_record_write
                             && payload_last
                             && (expected_fragment_index
                                 == assembly_fragment_count)
                             && (next_write_offset != STRIPE_BYTES);
    wire [1:0] bank_set_mask = invalid_raw_release
        ? (assembly_bank ? 2'b10 : 2'b01) : 2'b00;
    wire [1:0] bank_available_next =
        ((bank_available | bank_release_mask) & ~bank_clear_mask)
        | bank_set_mask;
    wire raw_write_fire = payload_fire && current_record_write
                        && (stripe_write_offset < STRIPE_BYTES);
    wire selected_write_valid = decoded_pipeline_valid || raw_pipeline_valid;
    wire selected_write_bank = decoded_pipeline_valid
                             ? decoded_pipeline_bank : raw_pipeline_bank;
    wire [1:0] selected_write_plane = decoded_pipeline_valid
        ? decoded_pipeline_plane : raw_pipeline_plane;
    wire [14:0] selected_y_write_address = decoded_pipeline_valid
        ? decoded_pipeline_address : raw_pipeline_y_address;
    wire [12:0] selected_c_write_address = decoded_pipeline_valid
        ? decoded_pipeline_address[12:0] : raw_pipeline_c_address;
    wire [7:0] selected_write_data = decoded_pipeline_valid
        ? decoded_pipeline_data : raw_pipeline_data;

    always_ff @(posedge write_clk) begin
        if (selected_write_valid) begin
            case (selected_write_plane)
                2'd0: begin
                    if (selected_write_bank)
                        y_bank1[selected_y_write_address]
                            <= selected_write_data;
                    else
                        y_bank0[selected_y_write_address]
                            <= selected_write_data;
                end
                2'd1: begin
                    if (selected_write_bank)
                        u_bank1[selected_c_write_address]
                            <= selected_write_data;
                    else
                        u_bank0[selected_c_write_address]
                            <= selected_write_data;
                end
                default: begin
                    if (selected_write_bank)
                        v_bank1[selected_c_write_address]
                            <= selected_write_data;
                    else
                        v_bank0[selected_c_write_address]
                            <= selected_write_data;
                end
            endcase
        end
    end

    // Pixel-domain ownership is returned only after the final pixel pipeline
    // has left a stripe. The two-flop toggle synchronizer is the only CDC path
    // that can make a bank writable again.
    logic [1:0] bank_release_toggle_pixel;
    always_ff @(posedge write_clk) begin
        if (!write_rst_n) begin
            bank_release_sync1 <= 2'b00;
            bank_release_sync2 <= 2'b00;
        end else begin
            bank_release_sync1 <= bank_release_toggle_pixel;
            bank_release_sync2 <= bank_release_sync1;
        end
    end

    integer write_bank_index;
    always_ff @(posedge write_clk) begin
        if (!write_rst_n) begin
            bank_available <= 2'b11;
            free_bank_available_registered <= 1'b1;
            reserve_bank_index_registered <= 1'b0;
            bank_ready_write <= 2'b00;
            bank_release_seen <= 2'b00;
            bank_frame_id[0] <= 16'd0;
            bank_frame_id[1] <= 16'd0;
            bank_stripe_id[0] <= 8'd0;
            bank_stripe_id[1] <= 8'd0;
            assembly_active <= 1'b0;
            assembly_bank <= 1'b0;
            assembly_frame_id <= 16'd0;
            assembly_stripe_id <= 8'd0;
            assembly_fragment_count <= 8'd0;
            expected_fragment_index <= 8'd0;
            stripe_write_offset <= 15'd0;
            current_record_write <= 1'b0;
            assembly_decoded <= 1'b0;
            decoded_pipeline_valid <= 1'b0;
            decoded_pipeline_bank <= 1'b0;
            decoded_pipeline_last <= 1'b0;
            decoded_pipeline_plane <= 2'd0;
            decoded_pipeline_address <= 15'd0;
            decoded_pipeline_data <= 8'd0;
            raw_pipeline_valid <= 1'b0;
            raw_pipeline_bank <= 1'b0;
            raw_pipeline_plane <= 2'd0;
            raw_pipeline_y_address <= 15'd0;
            raw_pipeline_c_address <= 13'd0;
            raw_pipeline_data <= 8'd0;
            completed_stripe_count <= 32'd0;
            rejected_stripe_count <= 32'd0;
        end else begin
            bank_available <= bank_available_next;
            free_bank_available_registered <= |bank_available_next;
            reserve_bank_index_registered <= !bank_available_next[0];
            decoded_pipeline_valid <= decoded_fire;
            raw_pipeline_valid <= raw_write_fire;
            if (decoded_fire) begin
                decoded_pipeline_bank <= decoded_target_bank;
                decoded_pipeline_last <= decoded_write_last;
                decoded_pipeline_plane <= decoded_plane;
                decoded_pipeline_address <= decoded_address;
                decoded_pipeline_data <= decoded_data;
            end
            if (raw_write_fire) begin
                raw_pipeline_bank <= assembly_bank;
                raw_pipeline_plane <= (stripe_write_offset < Y_BYTES) ? 2'd0
                    : (stripe_write_offset < U_END) ? 2'd1 : 2'd2;
                raw_pipeline_y_address <= stripe_write_offset;
                raw_pipeline_c_address <= chroma_write_address;
                raw_pipeline_data <= payload_data;
            end
            for (write_bank_index = 0; write_bank_index < 2;
                 write_bank_index = write_bank_index + 1) begin
                if (bank_release_sync2[write_bank_index]
                    != bank_release_seen[write_bank_index]) begin
                    bank_release_seen[write_bank_index] <=
                        bank_release_sync2[write_bank_index];
                    bank_ready_write[write_bank_index] <= 1'b0;
                end
            end

            if (decoded_fire && decoded_write_start) begin
                if (!assembly_active) begin
                    assembly_bank <= reserve_bank_index;
                end
                assembly_active <= 1'b1;
                assembly_decoded <= 1'b1;
                assembly_frame_id <= decoded_frame_id;
                assembly_stripe_id <= decoded_stripe_id;
            end

            if (record_valid && record_ready) begin
                current_record_write <= 1'b0;

                if (record_type == RAW_YUV420_RECORD) begin
                    // Capture raw metadata on every accepted raw header. For
                    // valid fragments these fields are invariant; removing
                    // fragment_index from their CE cone shortens the debug
                    // parser path without changing the decoded-video path.
                    assembly_frame_id <= display_frame_id;
                    assembly_stripe_id <= stripe_id;
                    assembly_fragment_count <= fragment_count;
                    if (payload_length == 0) begin
                        rejected_stripe_count <= rejected_stripe_count + 1'b1;
                    end else if (fragment_index == 0) begin
                        // A new first fragment intentionally replaces an
                        // incomplete assembly; the reserved bank is reused.
                        if (!assembly_active) begin
                            assembly_bank <= reserve_bank_index;
                        end
                        assembly_active <= 1'b1;
                        assembly_decoded <= 1'b0;
                        expected_fragment_index <= 8'd1;
                        stripe_write_offset <= 15'd0;
                        current_record_write <= 1'b1;
                    end else if (assembly_active
                                 && (display_frame_id == assembly_frame_id)
                                 && (stripe_id == assembly_stripe_id)
                                 && (fragment_count
                                     == assembly_fragment_count)
                                 && (fragment_index
                                     == expected_fragment_index)) begin
                        expected_fragment_index <=
                            expected_fragment_index + 1'b1;
                        current_record_write <= 1'b1;
                    end else begin
                        rejected_stripe_count <= rejected_stripe_count + 1'b1;
                    end
                end
            end

            if (payload_fire && current_record_write) begin
                if (stripe_write_offset < STRIPE_BYTES)
                    stripe_write_offset <= next_write_offset;

                if (payload_last) begin
                    current_record_write <= 1'b0;
                    if ((expected_fragment_index
                         == assembly_fragment_count)
                        && (next_write_offset == STRIPE_BYTES)) begin
                        bank_frame_id[assembly_bank] <= assembly_frame_id;
                        bank_stripe_id[assembly_bank] <= assembly_stripe_id;
                        bank_ready_write[assembly_bank] <= 1'b1;
                        assembly_active <= 1'b0;
                        completed_stripe_count <=
                            completed_stripe_count + 1'b1;
                    end else if (expected_fragment_index
                                 == assembly_fragment_count) begin
                        // A last fragment with the wrong aggregate size makes
                        // the whole stripe unavailable to the display side.
                        assembly_active <= 1'b0;
                        rejected_stripe_count <= rejected_stripe_count + 1'b1;
                    end
                end
            end

            if (decoded_pipeline_valid && decoded_pipeline_last) begin
                bank_frame_id[decoded_pipeline_bank] <=
                    assembly_frame_id;
                bank_stripe_id[decoded_pipeline_bank] <=
                    assembly_stripe_id;
                bank_ready_write[decoded_pipeline_bank] <= 1'b1;
                assembly_active <= 1'b0;
                assembly_decoded <= 1'b0;
                completed_stripe_count <= completed_stripe_count + 1'b1;
            end
        end
    end

    logic [1:0] bank_ready_sync1, bank_ready_sync2;
    logic display_bank, display_bank_valid;
    logic [15:0] active_frame_id;
    logic active_frame_valid;

    wire [1:0] bank_pending = bank_ready_sync2;
    wire boundary_to_first = (x == 12'd1290) && (y == 10'd749);
    wire boundary_to_next = (x == 12'd1290) && (y < 10'd719)
                          && (y[3:0] == 4'hF);
    wire boundary_after_last = (x == 12'd1290) && (y == 10'd719);
    wire [7:0] next_stripe_id = boundary_to_first
                              ? 8'd0 : ({2'd0, y[9:4]} + 1'b1);
    wire bank0_matches = bank_pending[0]
        && (bank_stripe_id[0] == next_stripe_id)
        && (boundary_to_first || !active_frame_valid
            || (bank_frame_id[0] == active_frame_id));
    wire bank1_matches = bank_pending[1]
        && (bank_stripe_id[1] == next_stripe_id)
        && (boundary_to_first || !active_frame_valid
            || (bank_frame_id[1] == active_frame_id));
    wire bank0_stale = bank_pending[0] && !bank0_matches
        && (boundary_after_last
            || (boundary_to_next
                && (((active_frame_valid
                      && (bank_frame_id[0] != active_frame_id)))
                    || (bank_stripe_id[0] < next_stripe_id))));
    wire bank1_stale = bank_pending[1] && !bank1_matches
        && (boundary_after_last
            || (boundary_to_next
                && (((active_frame_valid
                      && (bank_frame_id[1] != active_frame_id)))
                    || (bank_stripe_id[1] < next_stripe_id))));

    always_ff @(posedge pixel_clk) begin
        if (!pixel_rst_n) begin
            bank_ready_sync1 <= 2'b00;
            bank_ready_sync2 <= 2'b00;
            bank_release_toggle_pixel <= 2'b00;
            display_bank <= 1'b0;
            display_bank_valid <= 1'b0;
            active_frame_id <= 16'd0;
            active_frame_valid <= 1'b0;
            displayed_stripe_count <= 32'd0;
            missing_stripe_count <= 32'd0;
        end else begin
            bank_ready_sync1 <= bank_ready_write;
            bank_ready_sync2 <= bank_ready_sync1;

            if (boundary_to_first || boundary_to_next
                || boundary_after_last) begin
                if (display_bank_valid) begin
                    bank_release_toggle_pixel[display_bank] <=
                        ~bank_release_toggle_pixel[display_bank];
                    display_bank_valid <= 1'b0;
                end

                if (boundary_to_first || boundary_to_next) begin
                    if (bank0_matches) begin
                        display_bank <= 1'b0;
                        display_bank_valid <= 1'b1;
                        displayed_stripe_count <=
                            displayed_stripe_count + 1'b1;
                        if (boundary_to_first || !active_frame_valid) begin
                            active_frame_id <= bank_frame_id[0];
                            active_frame_valid <= 1'b1;
                        end
                    end else if (bank1_matches) begin
                        display_bank <= 1'b1;
                        display_bank_valid <= 1'b1;
                        displayed_stripe_count <=
                            displayed_stripe_count + 1'b1;
                        if (boundary_to_first || !active_frame_valid) begin
                            active_frame_id <= bank_frame_id[1];
                            active_frame_valid <= 1'b1;
                        end
                    end else begin
                        missing_stripe_count <= missing_stripe_count + 1'b1;
                    end
                end

                // A completed stripe that has already missed its display
                // boundary must not occupy one of the only two banks until
                // the next frame. Drop stale banks here so the decoder can
                // keep running and use vertical blanking to reacquire phase.
                if (bank0_stale
                    && !(display_bank_valid && (display_bank == 1'b0)))
                    bank_release_toggle_pixel[0] <=
                        ~bank_release_toggle_pixel[0];
                if (bank1_stale
                    && !(display_bank_valid && (display_bank == 1'b1)))
                    bank_release_toggle_pixel[1] <=
                        ~bank_release_toggle_pixel[1];
            end
        end
    end

    logic [14:0] y_read_address;
    logic [12:0] c_read_address;
    always_comb begin
        y_read_address = 15'd0;
        c_read_address = 13'd0;
        if (data_enable) begin
            y_read_address = {1'b0, y[3:0], 10'd0}
                           + {3'd0, y[3:0], 8'd0} + {4'd0, x};
            c_read_address = {1'b0, y[3:1], 9'd0}
                           + {3'd0, y[3:1], 7'd0}
                           + {3'd0, x[10:1]};
        end
    end

    logic [7:0] y0_read, y1_read;
    logic [7:0] u0_read, u1_read;
    logic [7:0] v0_read, v1_read;
    always_ff @(posedge pixel_clk) begin
        y0_read <= y_bank0[y_read_address];
        y1_read <= y_bank1[y_read_address];
        u0_read <= u_bank0[c_read_address];
        u1_read <= u_bank1[c_read_address];
        v0_read <= v_bank0[c_read_address];
        v1_read <= v_bank1[c_read_address];
    end

    logic display_bank_d1, display_valid_d1;
    logic [7:0] selected_y_sample;
    logic [7:0] selected_u_sample;
    logic [7:0] selected_v_sample;
    logic signed [9:0] y_centered;
    logic signed [9:0] u_centered;
    logic signed [9:0] v_centered;
    always_comb begin
        y_centered = (selected_y_sample > 8'd16)
                   ? $signed({1'b0, selected_y_sample}) - 10'sd16 : 10'sd0;
        u_centered = $signed({1'b0, selected_u_sample}) - 10'sd128;
        v_centered = $signed({1'b0, selected_v_sample}) - 10'sd128;
    end

    logic signed [18:0] y_product, u_green_product, u_blue_product;
    logic signed [18:0] v_red_product, v_green_product;
    logic de_d1, de_d2, de_d3;
    logic hs_d1, hs_d2, hs_d3;
    logic vs_d1, vs_d2, vs_d3;

    function automatic [7:0] clip_rgb(input logic signed [19:0] value);
        begin
            if (value <= 0)
                clip_rgb = 8'd0;
            else if (value >= 20'sd65280)
                clip_rgb = 8'd255;
            else
                clip_rgb = value[15:8];
        end
    endfunction

    always_ff @(posedge pixel_clk) begin
        if (!pixel_rst_n) begin
            display_bank_d1 <= 1'b0;
            display_valid_d1 <= 1'b0;
            selected_y_sample <= 8'd126;
            selected_u_sample <= 8'd128;
            selected_v_sample <= 8'd128;
            y_product <= 19'sd0;
            u_green_product <= 19'sd0;
            u_blue_product <= 19'sd0;
            v_red_product <= 19'sd0;
            v_green_product <= 19'sd0;
            rgb <= 24'h808080;
            de_d1 <= 1'b0;
            de_d2 <= 1'b0;
            de_d3 <= 1'b0;
            data_enable_out <= 1'b0;
            hs_d1 <= 1'b0;
            hs_d2 <= 1'b0;
            hs_d3 <= 1'b0;
            hsync_out <= 1'b0;
            vs_d1 <= 1'b0;
            vs_d2 <= 1'b0;
            vs_d3 <= 1'b0;
            vsync_out <= 1'b0;
        end else begin
            display_bank_d1 <= display_bank;
            display_valid_d1 <= display_bank_valid && data_enable;
            if (display_valid_d1) begin
                if (display_bank_d1) begin
                    selected_y_sample <= y1_read;
                    selected_u_sample <= u1_read;
                    selected_v_sample <= v1_read;
                end else begin
                    selected_y_sample <= y0_read;
                    selected_u_sample <= u0_read;
                    selected_v_sample <= v0_read;
                end
            end else begin
                // Limited-range Y=126, Cb=Cr=128 converts to gray RGB 128.
                selected_y_sample <= 8'd126;
                selected_u_sample <= 8'd128;
                selected_v_sample <= 8'd128;
            end
            y_product <= y_centered * 10'sd298;
            u_green_product <= u_centered * 10'sd100;
            // 516 needs an 11-bit signed literal; 10'sd516 would wrap to
            // -508 and turn negative Cb into a false positive blue term.
            u_blue_product <= u_centered * 11'sd516;
            v_red_product <= v_centered * 10'sd409;
            v_green_product <= v_centered * 10'sd208;

            rgb <= {
                clip_rgb(y_product + v_red_product + 20'sd128),
                clip_rgb(y_product - u_green_product
                         - v_green_product + 20'sd128),
                clip_rgb(y_product + u_blue_product + 20'sd128)
            };

            de_d1 <= data_enable;
            de_d2 <= de_d1;
            de_d3 <= de_d2;
            data_enable_out <= de_d3;
            hs_d1 <= hsync;
            hs_d2 <= hs_d1;
            hs_d3 <= hs_d2;
            hsync_out <= hs_d3;
            vs_d1 <= vsync;
            vs_d2 <= vs_d1;
            vs_d3 <= vs_d2;
            vsync_out <= vs_d3;
        end
    end
endmodule
