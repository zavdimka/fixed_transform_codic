#pragma once

#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <memory>
#include <optional>
#include <span>
#include <string>
#include <vector>

namespace hdzero {

struct StripeRecord {
    std::uint8_t stripe_index = 0;
    std::uint8_t quality = 24;
    std::vector<std::uint8_t> base_data;
    std::size_t base_bits = 0;
    std::vector<std::uint8_t> enhancement_data;
    std::size_t enhancement_bits = 0;
};

struct CaptureFile {
    std::uint32_t expected_yuv_crc32 = 0;
    std::uint16_t maximum_record_size = 0;
    std::vector<StripeRecord> stripes;
};

struct CapturedFrame {
    std::uint16_t display_frame_id = 0;
    std::uint16_t source_frame_id = 0;
    CaptureFile capture;
};

struct Frame {
    std::size_t width = 0;
    std::size_t height = 0;
    std::vector<std::uint8_t> y;
    std::vector<std::uint8_t> cb;
    std::vector<std::uint8_t> cr;
};

enum class TransformProfile {
    jpeg_dct,
    bounded_iht,
};

struct DecodeOptions {
    std::size_t width = 1280;
    std::size_t height = 720;
    unsigned threads = 0;
    bool allow_partial = false;
    TransformProfile profile = TransformProfile::jpeg_dct;
};

struct DecodeStats {
    std::size_t stripe_count = 0;
    std::size_t base_bytes = 0;
    std::size_t enhancement_bytes = 0;
    double milliseconds = 0.0;
};

class LinkRecordAssembler {
public:
    explicit LinkRecordAssembler(std::size_t expected_stripes = 45);
    ~LinkRecordAssembler();
    LinkRecordAssembler(const LinkRecordAssembler&) = delete;
    LinkRecordAssembler& operator=(const LinkRecordAssembler&) = delete;

    std::optional<CapturedFrame> push(
        std::span<const std::uint8_t> record);
    std::uint64_t dropped_frames() const;
    std::uint64_t late_records() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

CaptureFile read_capture_file(const std::filesystem::path& path);
std::vector<CapturedFrame> read_capture_frames(
    const std::filesystem::path& path
);

Frame decode_frame(
    const CaptureFile& capture,
    const DecodeOptions& options,
    DecodeStats* stats = nullptr
);

std::uint32_t frame_crc32(const Frame& frame);

void write_yuv420(const std::filesystem::path& path, const Frame& frame);
void write_ppm(const std::filesystem::path& path, const Frame& frame);

}  // namespace hdzero
