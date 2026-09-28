#include "hdzero/codec.hpp"

#include <algorithm>
#include <charconv>
#include <cstdint>
#include <filesystem>
#include <iomanip>
#include <iostream>
#include <stdexcept>
#include <string_view>

namespace {

unsigned parse_unsigned(std::string_view text, std::string_view option) {
    unsigned value = 0;
    const auto [end, error] = std::from_chars(
        text.data(), text.data() + text.size(), value
    );
    if (error != std::errc{} || end != text.data() + text.size()) {
        throw std::runtime_error("invalid value for " + std::string(option));
    }
    return value;
}

void usage(const char* program) {
    std::cerr
        << "Usage: " << program << " INPUT.(rxt|hcap) [options]\n"
        << "Options:\n"
        << "  --output-yuv PATH   Write planar 8-bit YUV420\n"
        << "  --output-ppm PATH   Write dependency-free RGB preview\n"
        << "  --output-dir PATH   Write every complete frame as YUV and PPM\n"
        << "  --threads N         Stripe decoder workers (0 = automatic)\n"
        << "  --profile NAME      jpeg-dct (default) or bounded-iht\n"
        << "  --width N           Frame width (default 1280)\n"
        << "  --height N          Frame height (default 720)\n"
        << "  --verify-only       Decode and verify CRC without output\n";
}

}  // namespace

int main(int argc, char** argv) {
    try {
        if (argc < 2) {
            usage(argv[0]);
            return 2;
        }
        const std::filesystem::path input = argv[1];
        std::filesystem::path yuv_output;
        std::filesystem::path ppm_output;
        std::filesystem::path output_dir;
        hdzero::DecodeOptions options;
        bool verify_only = false;
        for (int index = 2; index < argc; ++index) {
            const std::string_view argument = argv[index];
            const auto next = [&](std::string_view option) -> std::string_view {
                if (++index >= argc) {
                    throw std::runtime_error(
                        "missing value for " + std::string(option)
                    );
                }
                return argv[index];
            };
            if (argument == "--output-yuv") {
                yuv_output = next(argument);
            } else if (argument == "--output-ppm") {
                ppm_output = next(argument);
            } else if (argument == "--output-dir") {
                output_dir = next(argument);
            } else if (argument == "--threads") {
                options.threads = parse_unsigned(next(argument), argument);
            } else if (argument == "--allow-partial") {
                options.allow_partial = true;
            } else if (argument == "--profile") {
                const std::string_view profile = next(argument);
                if (profile == "jpeg-dct") {
                    options.profile = hdzero::TransformProfile::jpeg_dct;
                } else if (profile == "bounded-iht") {
                    options.profile = hdzero::TransformProfile::bounded_iht;
                } else {
                    throw std::runtime_error("unknown transform profile");
                }
            } else if (argument == "--width") {
                options.width = parse_unsigned(next(argument), argument);
            } else if (argument == "--height") {
                options.height = parse_unsigned(next(argument), argument);
            } else if (argument == "--verify-only") {
                verify_only = true;
            } else if (argument == "--help" || argument == "-h") {
                usage(argv[0]);
                return 0;
            } else {
                throw std::runtime_error("unknown option: " + std::string(argument));
            }
        }

        const auto captured_frames = hdzero::read_capture_frames(input);
        const std::size_t required_stripes = options.height / 16;
        std::size_t decoded_count = 0;
        std::size_t skipped_count = 0;
        bool all_verified = true;
        if (!verify_only && !output_dir.empty()) {
            std::filesystem::create_directories(output_dir);
        }
        for (const auto& captured : captured_frames) {
            const auto& capture = captured.capture;
            if (capture.stripes.size() != required_stripes) {
                ++skipped_count;
                std::cout << (options.allow_partial ? "decode partial frame display="
                                                    : "skip partial frame display=")
                          << captured.display_frame_id << " source="
                          << captured.source_frame_id << " stripes="
                          << capture.stripes.size() << '/' << required_stripes
                          << '\n';
                if (!options.allow_partial) {
                    continue;
                }
            }
            hdzero::DecodeStats stats;
            const hdzero::Frame frame = hdzero::decode_frame(
                capture, options, &stats);
            const std::uint32_t crc = hdzero::frame_crc32(frame);
            const bool has_expected_crc = capture.expected_yuv_crc32 != 0;
            const bool matches = !has_expected_crc ||
                crc == capture.expected_yuv_crc32;
            all_verified = all_verified && matches;
            std::cout << "decoded frame display=" << captured.display_frame_id
                      << " source=" << captured.source_frame_id << ' '
                      << frame.width << 'x' << frame.height
                      << " stripes=" << stats.stripe_count
                      << " base=" << stats.base_bytes
                      << " enhancement=" << stats.enhancement_bytes
                      << " bytes\nYUV CRC32 actual=" << std::hex
                      << std::setfill('0') << std::setw(8) << crc;
            if (has_expected_crc) {
                std::cout << " expected=" << std::setw(8)
                          << capture.expected_yuv_crc32
                          << (matches ? " MATCH" : " MISMATCH");
            }
            std::cout << std::dec << "\ndecode=" << std::fixed
                      << std::setprecision(3) << stats.milliseconds << " ms, "
                      << (stats.milliseconds > 0.0
                          ? 1000.0 / stats.milliseconds : 0.0)
                      << " FPS\n";

            if (!verify_only) {
                if (!output_dir.empty()) {
                    const std::string stem = "frame_" +
                        std::to_string(captured.display_frame_id);
                    const auto yuv_path = output_dir / (stem + ".yuv");
                    const auto ppm_path = output_dir / (stem + ".ppm");
                    hdzero::write_yuv420(yuv_path, frame);
                    hdzero::write_ppm(ppm_path, frame);
                    std::cout << "wrote " << yuv_path.string() << " and "
                              << ppm_path.string() << '\n';
                }
                if (decoded_count == 0 && !yuv_output.empty()) {
                    hdzero::write_yuv420(yuv_output, frame);
                    std::cout << "wrote " << yuv_output.string() << '\n';
                }
                if (decoded_count == 0 && !ppm_output.empty()) {
                    hdzero::write_ppm(ppm_output, frame);
                    std::cout << "wrote " << ppm_output.string() << '\n';
                }
            }
            ++decoded_count;
        }
        std::cout << "capture summary: complete=" << decoded_count
                  << " partial=" << skipped_count << '\n';
        if (decoded_count == 0) {
            throw std::runtime_error("capture contains no complete frames");
        }
        return all_verified ? 0 : 1;
    } catch (const std::exception& error) {
        std::cerr << "hdzero_decode: " << error.what() << '\n';
        return 2;
    }
}
