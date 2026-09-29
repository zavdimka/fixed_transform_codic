#include "hdzero/codec.hpp"

#include <SDL2/SDL.h>

#include <arpa/inet.h>
#include <cerrno>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <fcntl.h>
#include <iostream>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>
#include <sys/socket.h>
#include <unistd.h>
#include <vector>

namespace {

volatile std::sig_atomic_t keep_running = 1;

void stop_handler(int) {
    keep_running = 0;
}

struct Options {
    std::string bind_address = "0.0.0.0";
    std::uint16_t port = 5600;
    unsigned threads = 0;
    std::uint64_t stop_after_frames = 0;
    bool headless = false;
    bool base_only = false;
    std::string output_ppm;
    std::string output_base_ppm;
};

unsigned parse_unsigned(const char* text, const char* option) {
    char* end = nullptr;
    errno = 0;
    const auto value = std::strtoul(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0' ||
        value > std::numeric_limits<unsigned>::max()) {
        throw std::runtime_error(std::string("invalid value for ") + option);
    }
    return static_cast<unsigned>(value);
}

Options parse_options(int argc, char** argv) {
    Options options;
    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        auto require_value = [&](const char* option) -> const char* {
            if (++i >= argc) {
                throw std::runtime_error(std::string("missing value for ") + option);
            }
            return argv[i];
        };

        if (arg == "--bind") {
            options.bind_address = require_value("--bind");
        } else if (arg == "--port") {
            const auto value = parse_unsigned(require_value("--port"), "--port");
            if (value == 0 || value > 65535) {
                throw std::runtime_error("--port must be in range 1..65535");
            }
            options.port = static_cast<std::uint16_t>(value);
        } else if (arg == "--threads") {
            options.threads = parse_unsigned(require_value("--threads"), "--threads");
        } else if (arg == "--frames") {
            options.stop_after_frames = parse_unsigned(require_value("--frames"), "--frames");
        } else if (arg == "--headless") {
            options.headless = true;
        } else if (arg == "--base-only") {
            options.base_only = true;
        } else if (arg == "--output-ppm") {
            options.output_ppm = require_value("--output-ppm");
        } else if (arg == "--output-base-ppm") {
            options.output_base_ppm = require_value("--output-base-ppm");
        } else if (arg == "--help" || arg == "-h") {
            std::cout << "Usage: hdzero_live [--bind ADDRESS] [--port N] [--threads N] "
                         "[--frames N] [--headless] [--base-only] "
                         "[--output-ppm PATH] [--output-base-ppm PATH]\n";
            std::exit(0);
        } else {
            throw std::runtime_error("unknown option: " + arg);
        }
    }
    return options;
}

class Socket {
public:
    explicit Socket(int fd) : fd_(fd) {}
    ~Socket() {
        if (fd_ >= 0) {
            ::close(fd_);
        }
    }
    Socket(const Socket&) = delete;
    Socket& operator=(const Socket&) = delete;
    int get() const { return fd_; }

private:
    int fd_;
};

class SdlDisplay {
public:
    explicit SdlDisplay(bool headless) : headless_(headless) {
        if (headless_) {
            return;
        }
        if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS) != 0) {
            throw std::runtime_error(std::string("SDL_Init failed: ") + SDL_GetError());
        }
        window_ = SDL_CreateWindow("HDZero UDP receiver", SDL_WINDOWPOS_CENTERED,
                                   SDL_WINDOWPOS_CENTERED, 1280, 720,
                                   SDL_WINDOW_SHOWN | SDL_WINDOW_RESIZABLE);
        if (!window_) {
            throw std::runtime_error(std::string("SDL_CreateWindow failed: ") + SDL_GetError());
        }
        renderer_ = SDL_CreateRenderer(window_, -1,
                                       SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
        if (!renderer_) {
            renderer_ = SDL_CreateRenderer(window_, -1, SDL_RENDERER_SOFTWARE);
        }
        if (!renderer_) {
            throw std::runtime_error(std::string("SDL_CreateRenderer failed: ") + SDL_GetError());
        }
        SDL_RenderSetLogicalSize(renderer_, 1280, 720);
        texture_ = SDL_CreateTexture(renderer_, SDL_PIXELFORMAT_IYUV,
                                     SDL_TEXTUREACCESS_STREAMING, 1280, 720);
        if (!texture_) {
            throw std::runtime_error(std::string("SDL_CreateTexture failed: ") + SDL_GetError());
        }
    }

    ~SdlDisplay() {
        if (texture_) SDL_DestroyTexture(texture_);
        if (renderer_) SDL_DestroyRenderer(renderer_);
        if (window_) SDL_DestroyWindow(window_);
        if (!headless_) SDL_Quit();
    }

    bool pump_events() {
        if (headless_) return true;
        SDL_Event event;
        while (SDL_PollEvent(&event)) {
            if (event.type == SDL_QUIT) return false;
            if (event.type == SDL_KEYDOWN && event.key.keysym.sym == SDLK_ESCAPE) return false;
        }
        return true;
    }

    void show(const hdzero::Frame& frame) {
        if (headless_) return;
        const std::size_t y_size = 1280u * 720u;
        const std::size_t chroma_size = 640u * 360u;
        if (frame.width != 1280 || frame.height != 720 ||
            frame.y.size() != y_size || frame.cb.size() != chroma_size ||
            frame.cr.size() != chroma_size) {
            throw std::runtime_error("decoder returned an unexpected frame size");
        }
        if (SDL_UpdateYUVTexture(texture_, nullptr,
                                 frame.y.data(), 1280,
                                 frame.cb.data(), 640,
                                 frame.cr.data(), 640) != 0) {
            throw std::runtime_error(std::string("SDL_UpdateYUVTexture failed: ") + SDL_GetError());
        }
        SDL_RenderClear(renderer_);
        SDL_RenderCopy(renderer_, texture_, nullptr, nullptr);
        SDL_RenderPresent(renderer_);
    }

private:
    bool headless_;
    SDL_Window* window_ = nullptr;
    SDL_Renderer* renderer_ = nullptr;
    SDL_Texture* texture_ = nullptr;
};

}  // namespace

int main(int argc, char** argv) {
    try {
        const Options options = parse_options(argc, argv);
        std::signal(SIGINT, stop_handler);
        std::signal(SIGTERM, stop_handler);

        const int fd = ::socket(AF_INET, SOCK_DGRAM, 0);
        if (fd < 0) throw std::runtime_error(std::string("socket failed: ") + std::strerror(errno));
        Socket socket(fd);

        int receive_buffer = 8 * 1024 * 1024;
        ::setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receive_buffer, sizeof(receive_buffer));
        const int flags = ::fcntl(fd, F_GETFL, 0);
        if (flags < 0 || ::fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
            throw std::runtime_error(std::string("fcntl failed: ") + std::strerror(errno));
        }

        sockaddr_in address{};
        address.sin_family = AF_INET;
        address.sin_port = htons(options.port);
        if (::inet_pton(AF_INET, options.bind_address.c_str(), &address.sin_addr) != 1) {
            throw std::runtime_error("invalid IPv4 bind address: " + options.bind_address);
        }
        if (::bind(fd, reinterpret_cast<const sockaddr*>(&address), sizeof(address)) < 0) {
            throw std::runtime_error(std::string("bind failed: ") + std::strerror(errno));
        }

        SdlDisplay display(options.headless);
        hdzero::LinkRecordAssembler assembler;
        hdzero::DecodeOptions decode_options;
        decode_options.width = 1280;
        decode_options.height = 720;
        decode_options.threads = options.threads;

        std::vector<std::uint8_t> record(2048);
        std::uint64_t packets = 0;
        std::uint64_t records_received = 0;
        std::uint64_t bytes = 0;
        std::uint64_t invalid = 0;
        std::uint64_t sequence_discontinuities = 0;
        std::uint64_t decoded_frames = 0;
        std::uint64_t decode_errors = 0;
        bool have_sequence = false;
        std::uint16_t last_sequence = 0;
        auto report_time = std::chrono::steady_clock::now();
        std::uint64_t report_packets = 0;
        std::uint64_t report_records = 0;
        std::uint64_t report_bytes = 0;

        std::cout << "Listening on " << options.bind_address << ':' << options.port
                  << (options.headless ? " (headless)" : "") << '\n';

        auto process_record = [&](std::span<const std::uint8_t> link_record) {
            ++records_received;
            if (link_record.size() >= 6) {
                const auto sequence = static_cast<std::uint16_t>(link_record[4]) |
                    (static_cast<std::uint16_t>(link_record[5]) << 8);
                if (have_sequence) {
                    const auto expected = static_cast<std::uint16_t>(last_sequence + 1u);
                    if (sequence != expected) {
                        ++sequence_discontinuities;
                    }
                }
                last_sequence = sequence;
                have_sequence = true;
            }

            auto captured = assembler.push(link_record);
            if (!captured) {
                if (link_record.size() < 16) ++invalid;
                return false;
            }
            try {
                if (options.base_only) {
                    for (auto& stripe : captured->capture.stripes) {
                        stripe.enhancement_data.clear();
                        stripe.enhancement_bits = 0;
                    }
                }
                const auto decoded = hdzero::decode_frame(
                    captured->capture, decode_options);
                if (!options.output_ppm.empty()) {
                    hdzero::write_ppm(options.output_ppm, decoded);
                }
                if (!options.output_base_ppm.empty()) {
                    for (auto& stripe : captured->capture.stripes) {
                        stripe.enhancement_data.clear();
                        stripe.enhancement_bits = 0;
                    }
                    const auto base_decoded = hdzero::decode_frame(
                        captured->capture, decode_options);
                    hdzero::write_ppm(options.output_base_ppm, base_decoded);
                }
                display.show(decoded);
                ++decoded_frames;
            } catch (const std::exception& error) {
                ++decode_errors;
                if (decode_errors <= 4 || (decode_errors & 0x3fU) == 0) {
                    std::cerr << "dropping undecodable frame "
                              << captured->display_frame_id << ": "
                              << error.what() << '\n';
                }
            }
            return options.stop_after_frames != 0 &&
                   decoded_frames >= options.stop_after_frames;
        };

        bool stop_after_frame = false;
        while (keep_running && !stop_after_frame && display.pump_events()) {
            const ssize_t received = ::recv(fd, record.data(), record.size(), 0);
            if (received < 0) {
                if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                    throw std::runtime_error(std::string("recv failed: ") + std::strerror(errno));
                }
                SDL_Delay(1);
            } else {
                ++packets;
                bytes += static_cast<std::uint64_t>(received);
                const auto datagram = std::span<const std::uint8_t>(
                    record.data(), static_cast<std::size_t>(received));
                if (datagram.size() >= 4 && datagram[0] == 'H' &&
                    datagram[1] == 'Z' && datagram[2] == 'U' &&
                    datagram[3] == 1) {
                    std::size_t cursor = 4;
                    while (cursor + 2 <= datagram.size()) {
                        const std::size_t record_length = datagram[cursor] |
                            (static_cast<std::size_t>(datagram[cursor + 1]) << 8);
                        cursor += 2;
                        if (record_length < 20 ||
                            cursor + record_length > datagram.size()) {
                            ++invalid;
                            break;
                        }
                        stop_after_frame |= process_record(
                            datagram.subspan(cursor, record_length));
                        cursor += record_length;
                    }
                    if (cursor != datagram.size()) ++invalid;
                } else {
                    stop_after_frame = process_record(datagram);
                }
            }

            const auto now = std::chrono::steady_clock::now();
            if (now - report_time >= std::chrono::seconds(1)) {
                const double seconds = std::chrono::duration<double>(now - report_time).count();
                const auto interval_packets = packets - report_packets;
                const auto interval_records = records_received - report_records;
                const auto interval_bytes = bytes - report_bytes;
                std::cout << "udp=" << interval_packets / seconds << " pkt/s "
                          << interval_records / seconds << " records/s "
                          << (8.0 * static_cast<double>(interval_bytes) / seconds / 1.0e6)
                          << " Mbit/s seq_jump=" << sequence_discontinuities
                          << " invalid=" << invalid
                          << " frames=" << decoded_frames
                          << " decode_error=" << decode_errors
                          << " incomplete=" << assembler.dropped_frames()
                          << " late=" << assembler.late_records() << '\n';
                report_time = now;
                report_packets = packets;
                report_records = records_received;
                report_bytes = bytes;
            }
        }

        std::cout << "Stopped: packets=" << packets << " records=" << records_received
                  << " bytes=" << bytes
                  << " frames=" << decoded_frames
                  << " decode_error=" << decode_errors
                  << " incomplete=" << assembler.dropped_frames()
                  << " late=" << assembler.late_records() << '\n';
        return decoded_frames == 0 && options.stop_after_frames != 0 ? 2 : 0;
    } catch (const std::exception& error) {
        std::cerr << "hdzero_live: " << error.what() << '\n';
        return 1;
    }
}
