"""Minimal fixed-profile HEVC VPS/SPS/PPS RBSP construction."""

from __future__ import annotations

from dataclasses import dataclass, field


@dataclass
class BitWriter:
    """MSB-first fixed/Exp-Golomb writer used only for HEVC headers."""

    bits: list[int] = field(default_factory=list)

    def write(self, value: int, width: int) -> None:
        if width < 0 or value < 0 or value >= (1 << width):
            raise ValueError("value does not fit the requested unsigned width")
        self.bits.extend((value >> shift) & 1 for shift in range(width - 1, -1, -1))

    def ue(self, value: int) -> None:
        if value < 0:
            raise ValueError("ue(v) cannot encode a negative value")
        code_num = value + 1
        leading_zero_bits = code_num.bit_length() - 1
        self.bits.extend([0] * leading_zero_bits)
        self.write(code_num, leading_zero_bits + 1)

    def se(self, value: int) -> None:
        self.ue(-2 * value if value <= 0 else 2 * value - 1)

    def trailing_bits(self) -> None:
        self.bits.append(1)
        self.bits.extend([0] * ((-len(self.bits)) & 7))

    def to_bytes(self) -> bytes:
        if len(self.bits) & 7:
            raise ValueError("bitstream is not byte-aligned")
        output = bytearray()
        for offset in range(0, len(self.bits), 8):
            value = 0
            for bit in self.bits[offset:offset + 8]:
                value = (value << 1) | bit
            output.append(value)
        return bytes(output)


def _profile_tier_level(writer: BitWriter, level_idc: int) -> None:
    # Main profile, Main tier, progressive frame-only source. There are no
    # sub-layer PTL records because max_sub_layers_minus1 is fixed to zero.
    writer.write(0, 2)       # general_profile_space
    writer.write(0, 1)       # general_tier_flag
    writer.write(1, 5)       # general_profile_idc: Main
    writer.write(0x60000000, 32)  # compatibility with Main/Main10
    writer.write(1, 1)       # progressive_source_flag
    writer.write(0, 1)       # interlaced_source_flag
    writer.write(0, 1)       # non_packed_constraint_flag
    writer.write(1, 1)       # frame_only_constraint_flag
    writer.write(0, 44)      # Main-profile reserved/constraint/inbld fields
    writer.write(level_idc, 8)


def vps_rbsp(level_idc: int = 120) -> bytes:
    writer = BitWriter()
    writer.write(0, 4)       # vps_video_parameter_set_id
    writer.write(1, 1)       # vps_base_layer_internal_flag
    writer.write(1, 1)       # vps_base_layer_available_flag
    writer.write(0, 6)       # vps_max_layers_minus1
    writer.write(0, 3)       # vps_max_sub_layers_minus1
    writer.write(1, 1)       # vps_temporal_id_nesting_flag
    writer.write(0xFFFF, 16)
    _profile_tier_level(writer, level_idc)
    writer.write(1, 1)       # vps_sub_layer_ordering_info_present_flag
    writer.ue(2)             # vps_max_dec_pic_buffering_minus1[0]
    writer.ue(0)             # vps_max_num_reorder_pics[0]
    writer.ue(1)             # vps_max_latency_increase_plus1[0]
    writer.write(0, 6)       # vps_max_layer_id
    writer.ue(0)             # vps_num_layer_sets_minus1
    writer.write(0, 1)       # vps_timing_info_present_flag
    writer.write(0, 1)       # vps_extension_flag
    writer.trailing_bits()
    return writer.to_bytes()


def sps_rbsp(
    width: int = 1280,
    height: int = 720,
    fps: int = 60,
    level_idc: int = 120,
) -> bytes:
    if width <= 0 or height <= 0 or (width & 1) or (height & 1):
        raise ValueError("4:2:0 frame dimensions must be positive and even")
    if fps <= 0 or fps >= (1 << 32):
        raise ValueError("fps must fit a positive 32-bit VUI time scale")

    writer = BitWriter()
    writer.write(0, 4)       # sps_video_parameter_set_id
    writer.write(0, 3)       # sps_max_sub_layers_minus1
    writer.write(1, 1)       # sps_temporal_id_nesting_flag
    _profile_tier_level(writer, level_idc)
    writer.ue(0)             # sps_seq_parameter_set_id
    writer.ue(1)             # chroma_format_idc: 4:2:0
    writer.ue(width)
    writer.ue(height)
    writer.write(0, 1)       # conformance_window_flag
    writer.ue(0)             # bit_depth_luma_minus8
    writer.ue(0)             # bit_depth_chroma_minus8
    writer.ue(4)             # log2_max_pic_order_cnt_lsb_minus4
    writer.write(1, 1)       # sps_sub_layer_ordering_info_present_flag
    writer.ue(2)             # sps_max_dec_pic_buffering_minus1[0]
    writer.ue(0)             # sps_max_num_reorder_pics[0]
    writer.ue(1)             # sps_max_latency_increase_plus1[0]
    writer.ue(1)             # log2_min_luma_coding_block_size_minus3: 16
    writer.ue(2)             # log2_diff_max_min_luma_coding_block_size: 64
    writer.ue(0)             # log2_min_luma_transform_block_size_minus2: 4
    writer.ue(2)             # log2_diff_max_min_luma_transform_block_size: 16
    writer.ue(0)             # max_transform_hierarchy_depth_inter
    writer.ue(0)             # max_transform_hierarchy_depth_intra
    writer.write(0, 1)       # scaling_list_enabled_flag
    writer.write(0, 1)       # amp_enabled_flag
    writer.write(0, 1)       # sample_adaptive_offset_enabled_flag
    writer.write(0, 1)       # pcm_enabled_flag
    writer.ue(0)             # num_short_term_ref_pic_sets
    writer.write(0, 1)       # long_term_ref_pics_present_flag
    writer.write(0, 1)       # sps_temporal_mvp_enabled_flag
    writer.write(0, 1)       # strong_intra_smoothing_enabled_flag

    writer.write(1, 1)       # vui_parameters_present_flag
    writer.write(1, 1)       # aspect_ratio_info_present_flag
    writer.write(1, 8)       # aspect_ratio_idc: square pixels
    writer.write(0, 1)       # overscan_info_present_flag
    writer.write(1, 1)       # video_signal_type_present_flag
    writer.write(5, 3)       # video_format: unspecified
    writer.write(0, 1)       # video_full_range_flag
    writer.write(0, 1)       # colour_description_present_flag
    writer.write(0, 1)       # chroma_loc_info_present_flag
    writer.write(0, 1)       # neutral_chroma_indication_flag
    writer.write(0, 1)       # field_seq_flag
    writer.write(0, 1)       # frame_field_info_present_flag
    writer.write(0, 1)       # default_display_window_flag
    writer.write(1, 1)       # vui_timing_info_present_flag
    writer.write(1, 32)      # vui_num_units_in_tick
    writer.write(fps, 32)    # vui_time_scale
    writer.write(0, 1)       # vui_poc_proportional_to_timing_flag
    writer.write(0, 1)       # vui_hrd_parameters_present_flag
    writer.write(0, 1)       # bitstream_restriction_flag
    writer.write(0, 1)       # sps_extension_present_flag
    writer.trailing_bits()
    return writer.to_bytes()


def pps_rbsp(entropy_coding_sync: bool = False) -> bytes:
    writer = BitWriter()
    writer.ue(0)             # pps_pic_parameter_set_id
    writer.ue(0)             # pps_seq_parameter_set_id
    writer.write(0, 1)       # dependent_slice_segments_enabled_flag
    writer.write(0, 1)       # output_flag_present_flag
    writer.write(0, 3)       # num_extra_slice_header_bits
    writer.write(0, 1)       # sign_data_hiding_enabled_flag
    writer.write(0, 1)       # cabac_init_present_flag
    writer.ue(0)             # num_ref_idx_l0_default_active_minus1
    writer.ue(0)             # num_ref_idx_l1_default_active_minus1
    writer.se(0)             # init_qp_minus26
    writer.write(0, 1)       # constrained_intra_pred_flag
    writer.write(0, 1)       # transform_skip_enabled_flag
    writer.write(0, 1)       # cu_qp_delta_enabled_flag
    writer.se(0)             # pps_cb_qp_offset
    writer.se(0)             # pps_cr_qp_offset
    writer.write(0, 1)       # pps_slice_chroma_qp_offsets_present_flag
    writer.write(0, 1)       # weighted_pred_flag
    writer.write(0, 1)       # weighted_bipred_flag
    writer.write(0, 1)       # transquant_bypass_enabled_flag
    writer.write(0, 1)       # tiles_enabled_flag
    writer.write(int(entropy_coding_sync), 1)
    writer.write(0, 1)       # pps_loop_filter_across_slices_enabled_flag
    writer.write(1, 1)       # deblocking_filter_control_present_flag
    writer.write(0, 1)       # deblocking_filter_override_enabled_flag
    writer.write(1, 1)       # pps_deblocking_filter_disabled_flag
    writer.write(0, 1)       # pps_scaling_list_data_present_flag
    writer.write(0, 1)       # lists_modification_present_flag
    writer.ue(0)             # log2_parallel_merge_level_minus2
    writer.write(0, 1)       # slice_segment_header_extension_present_flag
    writer.write(0, 1)       # pps_extension_present_flag
    writer.trailing_bits()
    return writer.to_bytes()


def parameter_set_rbsps(
    width: int = 1280,
    height: int = 720,
    fps: int = 60,
) -> tuple[bytes, bytes, bytes]:
    return vps_rbsp(), sps_rbsp(width, height, fps), pps_rbsp()
