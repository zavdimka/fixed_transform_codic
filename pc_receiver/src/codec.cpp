#include "hdzero/codec.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstring>
#include <fstream>
#include <limits>
#include <map>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <thread>
#include <utility>

namespace hdzero {
namespace {

constexpr std::array<std::uint8_t, 8> kFileMagic{
    'H', 'D', 'Z', 'R', 'X', 'T', '1', 0,
};
constexpr std::array<std::uint8_t, 4> kRecordMagic{0xc5, 0x3a, 0x01, 0};
constexpr std::array<std::uint8_t, 8> kCaptureMagic{
    'H', 'D', 'Z', 'C', 'A', 'P', '1', 0,
};
constexpr std::uint8_t kBaseRecord = 0x10;
constexpr std::uint8_t kEnhancementRecord = 0x11;
constexpr std::size_t kStripeHeight = 16;
constexpr std::size_t kLumaBaseCount = 6;
constexpr std::size_t kChromaBaseCount = 3;

constexpr std::array<std::uint8_t, 64> kZigzagAddress{
    0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5,
    12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
};

using QuantTable = std::array<std::int32_t, 64>;

constexpr std::array<std::int32_t, 64> kDctQ14{
    5793, 5793, 5793, 5793, 5793, 5793, 5793, 5793,
    8035, 6811, 4551, 1598, -1598, -4551, -6811, -8035,
    7568, 3135, -3135, -7568, -7568, -3135, 3135, 7568,
    6811, -1598, -8035, -4551, 4551, 8035, 1598, -6811,
    5793, -5793, -5793, 5793, 5793, -5793, -5793, 5793,
    4551, -8035, 1598, 6811, -6811, -1598, 8035, -4551,
    3135, -7568, 7568, -3135, -3135, 7568, -7568, 3135,
    1598, -4551, 6811, -8035, 8035, -6811, 4551, -1598,
};

constexpr QuantTable kLumaQuantBase{
    16, 11, 10, 16, 24, 40, 51, 61,
    12, 12, 14, 19, 26, 58, 60, 55,
    14, 13, 16, 24, 40, 57, 69, 56,
    14, 17, 22, 29, 51, 87, 80, 62,
    18, 22, 37, 56, 68, 109, 103, 77,
    24, 35, 55, 64, 81, 104, 113, 92,
    49, 64, 78, 87, 103, 121, 120, 101,
    72, 92, 95, 98, 112, 100, 103, 99,
};

constexpr QuantTable kChromaQuantBase{
    17, 18, 24, 47, 99, 99, 99, 99,
    18, 21, 26, 66, 99, 99, 99, 99,
    24, 26, 56, 99, 99, 99, 99, 99,
    47, 66, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
};

constexpr char kStandardDhtHex[] =
    "0000010501010101010100000000000000000102030405060708090a0b"
    "100002010303020403050504040000017d01020300041105122131410613516107"
    "227114328191a1082342b1c11552d1f02433627282090a161718191a2526272829"
    "2a3435363738393a434445464748494a535455565758595a636465666768696a73"
    "7475767778797a838485868788898a92939495969798999aa2a3a4a5a6a7a8a9"
    "aab2b3b4b5b6b7b8b9bac2c3c4c5c6c7c8c9cad2d3d4d5d6d7d8d9dae1e2e3"
    "e4e5e6e7e8e9eaf1f2f3f4f5f6f7f8f9fa"
    "0100030101010101010101010000000000000102030405060708090a0b"
    "110002010204040304070504040001027700010203110405213106124151076171"
    "1322328108144291a1b1c109233352f0156272d10a162434e125f11718191a2627"
    "28292a35363738393a434445464748494a535455565758595a636465666768696a"
    "737475767778797a82838485868788898a92939495969798999aa2a3a4a5a6a7"
    "a8a9aab2b3b4b5b6b7b8b9bac2c3c4c5c6c7c8c9cad2d3d4d5d6d7d8d9dae2"
    "e3e4e5e6e7e8e9eaf2f3f4f5f6f7f8f9fa";

[[noreturn]] void fail(const std::string& message) {
    throw std::runtime_error(message);
}

std::uint16_t read_le16(std::span<const std::uint8_t> bytes,
                        std::size_t offset) {
    if (offset + 2 > bytes.size()) {
        fail("truncated little-endian uint16");
    }
    return static_cast<std::uint16_t>(bytes[offset]) |
           static_cast<std::uint16_t>(bytes[offset + 1] << 8);
}

std::uint32_t read_le32(std::span<const std::uint8_t> bytes,
                        std::size_t offset) {
    if (offset + 4 > bytes.size()) {
        fail("truncated little-endian uint32");
    }
    return static_cast<std::uint32_t>(bytes[offset]) |
           (static_cast<std::uint32_t>(bytes[offset + 1]) << 8) |
           (static_cast<std::uint32_t>(bytes[offset + 2]) << 16) |
           (static_cast<std::uint32_t>(bytes[offset + 3]) << 24);
}

std::uint16_t crc16_ccitt(std::span<const std::uint8_t> bytes) {
    std::uint16_t crc = 0xffff;
    for (const std::uint8_t value : bytes) {
        crc ^= static_cast<std::uint16_t>(value) << 8;
        for (unsigned bit = 0; bit < 8; ++bit) {
            crc = static_cast<std::uint16_t>(
                (crc & 0x8000) ? (crc << 1) ^ 0x1021 : crc << 1
            );
        }
    }
    return crc;
}

std::uint32_t crc32_update(std::uint32_t crc,
                           std::span<const std::uint8_t> bytes) {
    crc ^= 0xffffffffU;
    for (const std::uint8_t byte : bytes) {
        crc ^= byte;
        for (unsigned bit = 0; bit < 8; ++bit) {
            const std::uint32_t mask = 0U - (crc & 1U);
            crc = (crc >> 1) ^ (0xedb88320U & mask);
        }
    }
    return crc ^ 0xffffffffU;
}

std::vector<std::uint8_t> read_all(const std::filesystem::path& path) {
    std::ifstream stream(path, std::ios::binary | std::ios::ate);
    if (!stream) {
        fail("cannot open input file: " + path.string());
    }
    const auto length = stream.tellg();
    if (length < 0) {
        fail("cannot determine input size: " + path.string());
    }
    std::vector<std::uint8_t> bytes(static_cast<std::size_t>(length));
    stream.seekg(0);
    if (!bytes.empty() &&
        !stream.read(reinterpret_cast<char*>(bytes.data()), length)) {
        fail("cannot read input file: " + path.string());
    }
    return bytes;
}

class BitReader {
public:
    BitReader(std::span<const std::uint8_t> data, std::size_t bit_limit)
        : data_(data), bit_limit_(bit_limit) {
        if (bit_limit > data.size() * 8) {
            fail("entropy bit count exceeds payload size");
        }
    }

    [[nodiscard]] std::size_t position() const { return position_; }
    [[nodiscard]] std::size_t limit() const { return bit_limit_; }

    std::uint32_t read(unsigned count) {
        if (count > 16 || position_ + count > bit_limit_) {
            fail("entropy payload ended unexpectedly");
        }
        if (count == 0) {
            return 0;
        }
        const std::uint32_t value = peek16() >> (16 - count);
        position_ += count;
        return value;
    }

    void skip(unsigned count) {
        if (position_ + count > bit_limit_) {
            fail("entropy payload ended inside Huffman code");
        }
        position_ += count;
    }

    [[nodiscard]] std::uint16_t peek16() const {
        const std::size_t byte_index = position_ >> 3;
        const unsigned offset = static_cast<unsigned>(position_ & 7);
        std::uint32_t word = 0;
        for (unsigned index = 0; index < 3; ++index) {
            word <<= 8;
            if (byte_index + index < data_.size()) {
                word |= data_[byte_index + index];
            }
        }
        std::uint16_t value = static_cast<std::uint16_t>(
            ((word << offset) >> 8) & 0xffffU
        );
        const std::size_t remaining = bit_limit_ - position_;
        if (remaining < 16) {
            value &= static_cast<std::uint16_t>(0xffffU << (16 - remaining));
        }
        return value;
    }

private:
    std::span<const std::uint8_t> data_;
    std::size_t bit_limit_ = 0;
    std::size_t position_ = 0;
};

struct HuffmanEntry {
    std::uint8_t symbol = 0;
    std::uint8_t length = 0;
};

class HuffmanTables {
public:
    HuffmanTables() {
        std::vector<std::uint8_t> raw;
        const std::size_t length = std::strlen(kStandardDhtHex);
        if (length & 1U) {
            fail("internal DHT hexadecimal string has odd length");
        }
        raw.reserve(length / 2);
        for (std::size_t index = 0; index < length; index += 2) {
            raw.push_back(static_cast<std::uint8_t>(
                (hex_digit(kStandardDhtHex[index]) << 4) |
                hex_digit(kStandardDhtHex[index + 1])
            ));
        }

        std::size_t position = 0;
        while (position < raw.size()) {
            const std::uint8_t table_info = raw[position++];
            const unsigned table_class = table_info >> 4;
            const unsigned table_id = table_info & 0x0f;
            if (table_class > 1 || table_id > 1 || position + 16 > raw.size()) {
                fail("invalid embedded Huffman table header");
            }
            std::array<unsigned, 16> counts{};
            std::size_t symbol_count = 0;
            for (unsigned index = 0; index < 16; ++index) {
                counts[index] = raw[position++];
                symbol_count += counts[index];
            }
            if (position + symbol_count > raw.size()) {
                fail("truncated embedded Huffman symbols");
            }

            auto& table = tables_[table_class * 2 + table_id];
            table.resize(65536);
            unsigned code = 0;
            for (unsigned length_index = 0; length_index < 16; ++length_index) {
                const unsigned code_length = length_index + 1;
                for (unsigned item = 0; item < counts[length_index]; ++item) {
                    const std::uint8_t symbol = raw[position++];
                    const unsigned begin = code << (16 - code_length);
                    const unsigned end = (code + 1) << (16 - code_length);
                    for (unsigned prefix = begin; prefix < end; ++prefix) {
                        table[prefix] = HuffmanEntry{
                            symbol, static_cast<std::uint8_t>(code_length)
                        };
                    }
                    ++code;
                }
                code <<= 1;
            }
        }
    }

    std::uint8_t decode(BitReader& reader, unsigned table_class,
                        unsigned table_id) const {
        if (table_class > 1 || table_id > 1) {
            fail("invalid Huffman table selector");
        }
        const auto& table = tables_[table_class * 2 + table_id];
        const HuffmanEntry entry = table[reader.peek16()];
        if (entry.length == 0) {
            fail("invalid Huffman code");
        }
        reader.skip(entry.length);
        return entry.symbol;
    }

    static const HuffmanTables& instance() {
        static const HuffmanTables tables;
        return tables;
    }

private:
    static unsigned hex_digit(char value) {
        if (value >= '0' && value <= '9') {
            return static_cast<unsigned>(value - '0');
        }
        if (value >= 'a' && value <= 'f') {
            return static_cast<unsigned>(value - 'a' + 10);
        }
        if (value >= 'A' && value <= 'F') {
            return static_cast<unsigned>(value - 'A' + 10);
        }
        fail("invalid embedded hexadecimal digit");
    }

    std::array<std::vector<HuffmanEntry>, 4> tables_;
};

int amplitude_value(std::uint32_t raw, unsigned category) {
    if (category == 0) {
        return 0;
    }
    if (raw < (1U << (category - 1))) {
        return static_cast<int>(raw) - static_cast<int>((1U << category) - 1);
    }
    return static_cast<int>(raw);
}

void decode_ac_segment(BitReader& reader, std::span<int> destination,
                       unsigned table_id, bool presence_prefix) {
    std::fill(destination.begin(), destination.end(), 0);
    if (presence_prefix && reader.read(1) == 0) {
        return;
    }
    std::size_t index = 0;
    const HuffmanTables& tables = HuffmanTables::instance();
    while (index < destination.size()) {
        const std::uint8_t symbol = tables.decode(reader, 1, table_id);
        if (symbol == 0x00) {
            break;
        }
        if (symbol == 0xf0) {
            index += 16;
            if (index > destination.size()) {
                fail("ZRL crosses layered coefficient segment");
            }
            continue;
        }
        const unsigned run = symbol >> 4;
        const unsigned size = symbol & 15;
        index += run;
        if (size == 0 || size > 11 || index >= destination.size()) {
            fail("invalid layered AC symbol");
        }
        destination[index++] = amplitude_value(reader.read(size), size);
    }
}

using Block = std::array<std::int32_t, 64>;
using Vector8 = std::array<std::int32_t, 8>;

std::int64_t floor_shift(std::int64_t value, unsigned shift) {
    if (shift == 0) {
        return value;
    }
    if (value >= 0) {
        return value >> shift;
    }
    const std::int64_t magnitude = -value;
    return -((magnitude + ((std::int64_t{1} << shift) - 1)) >> shift);
}

Vector8 inverse_iht8_1d(const Vector8& values) {
    const std::int32_t c0 = values[0];
    const std::int32_t c1 = values[1];
    const std::int32_t c2 = values[2];
    const std::int32_t c3 = values[3];
    const std::int32_t c4 = values[4];
    const std::int32_t c5 = values[5];
    const std::int32_t c6 = values[6];
    const std::int32_t c7 = values[7];
    const std::int32_t a0 = c0 + c4;
    const std::int32_t a2 = c0 - c4;
    const std::int32_t a4 = static_cast<std::int32_t>(floor_shift(c2, 1)) - c6;
    const std::int32_t a6 = c2 + static_cast<std::int32_t>(floor_shift(c6, 1));
    const std::int32_t a1 = -c3 + c5 - c7 -
                            static_cast<std::int32_t>(floor_shift(c7, 1));
    const std::int32_t a3 = c1 + c7 - c3 -
                            static_cast<std::int32_t>(floor_shift(c3, 1));
    const std::int32_t a5 = -c1 + c7 + c5 +
                            static_cast<std::int32_t>(floor_shift(c5, 1));
    const std::int32_t a7 = c3 + c5 + c1 +
                            static_cast<std::int32_t>(floor_shift(c1, 1));
    const std::int32_t b0 = a0 + a6;
    const std::int32_t b2 = a2 + a4;
    const std::int32_t b4 = a2 - a4;
    const std::int32_t b6 = a0 - a6;
    const std::int32_t b1 = a1 + static_cast<std::int32_t>(floor_shift(a7, 2));
    const std::int32_t b3 = a3 + static_cast<std::int32_t>(floor_shift(a5, 2));
    const std::int32_t b5 = static_cast<std::int32_t>(floor_shift(a3, 2)) - a5;
    const std::int32_t b7 = a7 - static_cast<std::int32_t>(floor_shift(a1, 2));
    return {
        b0 + b7, b2 + b5, b4 + b3, b6 + b1,
        b6 - b1, b4 - b3, b2 - b5, b0 - b7,
    };
}

unsigned weight_shift(unsigned address) {
    const unsigned diagonal = (address >> 3) + (address & 7);
    if (diagonal <= 1) {
        return 0;
    }
    if (diagonal <= 3) {
        return 1;
    }
    if (diagonal <= 5) {
        return 2;
    }
    return 3;
}

Block inverse_bounded_block(const std::array<int, 64>& coefficients,
                            unsigned quant_shift) {
    Block matrix{};
    for (unsigned address = 0; address < 64; ++address) {
        const unsigned shift = std::min(quant_shift + weight_shift(address), 6U);
        matrix[address] = static_cast<std::int32_t>(
            coefficients[address] * (1U << shift));
    }

    Block rows{};
    for (unsigned row = 0; row < 8; ++row) {
        Vector8 input{};
        for (unsigned column = 0; column < 8; ++column) {
            input[column] = matrix[row * 8 + column];
        }
        const Vector8 output = inverse_iht8_1d(input);
        for (unsigned column = 0; column < 8; ++column) {
            rows[row * 8 + column] = output[column];
        }
    }

    Block output{};
    for (unsigned column = 0; column < 8; ++column) {
        Vector8 input{};
        for (unsigned row = 0; row < 8; ++row) {
            input[row] = rows[row * 8 + column];
        }
        const Vector8 transformed = inverse_iht8_1d(input);
        for (unsigned row = 0; row < 8; ++row) {
            const auto rounded = floor_shift(
                static_cast<std::int64_t>(transformed[row]) + 32, 6
            );
            output[row * 8 + column] = static_cast<std::int32_t>(
                std::clamp<std::int64_t>(rounded, -32768, 32767)
            );
        }
    }
    return output;
}

std::int64_t round_shift14(std::int64_t value) {
    constexpr std::int64_t kRounding = std::int64_t{1} << 13;
    const std::int64_t magnitude = value < 0 ? -value : value;
    const std::int64_t rounded = (magnitude + kRounding) >> 14;
    return value < 0 ? -rounded : rounded;
}

QuantTable scaled_quant_table(const QuantTable& base, unsigned quality) {
    quality = std::clamp(quality, 1U, 100U);
    const unsigned scale = quality < 50 ? 5000U / quality
                                        : 200U - quality * 2U;
    QuantTable result{};
    for (std::size_t index = 0; index < result.size(); ++index) {
        result[index] = static_cast<std::int32_t>(std::clamp(
            (base[index] * static_cast<std::int32_t>(scale) + 50) / 100,
            1, 255));
    }
    return result;
}

std::pair<QuantTable, QuantTable> layered_quant_tables(unsigned quality) {
    QuantTable luma = scaled_quant_table(kLumaQuantBase, quality);
    QuantTable chroma = scaled_quant_table(kChromaQuantBase, quality);
    const QuantTable fine_luma = scaled_quant_table(
        kLumaQuantBase, std::min(100U, quality + 2U));
    const QuantTable fine_chroma = scaled_quant_table(
        kChromaQuantBase, std::min(100U, quality + 2U));
    for (std::size_t index = 0; index < kLumaBaseCount; ++index) {
        const auto address = kZigzagAddress[index];
        luma[address] = fine_luma[address];
    }
    for (std::size_t index = 0; index < kChromaBaseCount; ++index) {
        const auto address = kZigzagAddress[index];
        chroma[address] = fine_chroma[address];
    }
    return {luma, chroma};
}

Block inverse_dct_block(const std::array<int, 64>& coefficients,
                        const QuantTable& quant_table) {
    Block matrix{};
    for (std::size_t index = 0; index < matrix.size(); ++index) {
        const std::int64_t dequantized =
            static_cast<std::int64_t>(coefficients[index]) * quant_table[index];
        matrix[index] = static_cast<std::int32_t>(
            std::clamp<std::int64_t>(dequantized, -32768, 32767));
    }

    Block first{};
    for (std::size_t row = 0; row < 8; ++row) {
        for (std::size_t column = 0; column < 8; ++column) {
            std::int64_t sum = 0;
            for (std::size_t index = 0; index < 8; ++index) {
                sum += static_cast<std::int64_t>(kDctQ14[index * 8 + row])
                     * matrix[index * 8 + column];
            }
            first[row * 8 + column] = static_cast<std::int32_t>(
                std::clamp<std::int64_t>(
                    round_shift14(sum), -(std::int64_t{1} << 17),
                    (std::int64_t{1} << 17) - 1));
        }
    }

    Block output{};
    for (std::size_t row = 0; row < 8; ++row) {
        for (std::size_t column = 0; column < 8; ++column) {
            std::int64_t sum = 0;
            for (std::size_t index = 0; index < 8; ++index) {
                sum += static_cast<std::int64_t>(first[row * 8 + index])
                     * kDctQ14[index * 8 + column];
            }
            output[row * 8 + column] =
                static_cast<std::int32_t>(round_shift14(sum));
        }
    }
    return output;
}

struct CoefficientPair {
    std::array<int, 64> base{};
    std::array<int, 64> full{};
};

CoefficientPair decode_block_coefficients(
    BitReader& base_reader,
    BitReader* enhancement_reader,
    unsigned table_id,
    std::size_t base_count
) {
    const HuffmanTables& tables = HuffmanTables::instance();
    const unsigned dc_size = tables.decode(base_reader, 0, table_id);
    if (dc_size > 11) {
        fail("invalid DC magnitude category");
    }
    std::array<int, 64> base_scan{};
    base_scan[0] = amplitude_value(base_reader.read(dc_size), dc_size);
    decode_ac_segment(
        base_reader,
        std::span<int>(base_scan).subspan(1, base_count - 1),
        table_id, table_id == 0
    );
    std::array<int, 64> full_scan = base_scan;
    if (enhancement_reader != nullptr) {
        decode_ac_segment(
            *enhancement_reader,
            std::span<int>(full_scan).subspan(base_count),
            table_id, table_id == 0
        );
    }

    CoefficientPair coefficients;
    for (std::size_t index = 0; index < 64; ++index) {
        const auto address = kZigzagAddress[index];
        coefficients.base[address] = base_scan[index];
        coefficients.full[address] = full_scan[index];
    }
    return coefficients;
}

std::vector<std::int16_t> make_predictor(
    const std::vector<std::uint8_t>& plane,
    std::size_t width,
    std::size_t x,
    std::size_t size,
    unsigned mode
) {
    std::vector<std::int16_t> predictor(size * size);
    if (mode == 0) {
        // The resource-bounded FPGA transmitter encodes every CTU against
        // the same closed-form DC reference; it has no reconstruction loop
        // from which to obtain the decoder's quantized left boundary.
        std::fill(predictor.begin(), predictor.end(), 128);
        return predictor;
    }
    if (mode == 2 && x != 0) {
        for (std::size_t row = 0; row < size; ++row) {
            const std::int16_t value = plane[row * width + x - 1];
            std::fill_n(predictor.begin() + static_cast<std::ptrdiff_t>(row * size),
                        size, value);
        }
        return predictor;
    }
    fail("intra mode requires unavailable top/left reference in stripe");
}

void reconstruct_block(
    std::vector<std::uint8_t>& plane,
    std::size_t plane_width,
    std::size_t destination_x,
    std::size_t destination_y,
    const std::vector<std::int16_t>& predictor,
    std::size_t predictor_width,
    std::size_t predictor_x,
    std::size_t predictor_y,
    const Block& residual
) {
    for (std::size_t row = 0; row < 8; ++row) {
        for (std::size_t column = 0; column < 8; ++column) {
            const int prediction = predictor[
                (predictor_y + row) * predictor_width + predictor_x + column
            ];
            const int value = prediction + residual[row * 8 + column];
            plane[(destination_y + row) * plane_width + destination_x + column] =
                static_cast<std::uint8_t>(std::clamp(value, 0, 255));
        }
    }
}

struct DecodedStripe {
    std::uint8_t stripe_index = 0;
    std::vector<std::uint8_t> y;
    std::vector<std::uint8_t> cb;
    std::vector<std::uint8_t> cr;
};

DecodedStripe decode_stripe(const StripeRecord& record, std::size_t width,
                             TransformProfile profile) {
    if (width == 0 || width % 16 != 0) {
        fail("frame width must be a positive multiple of 16");
    }
    BitReader base_reader(record.base_data, record.base_bits);
    std::optional<BitReader> enhancement_reader;
    if (!record.enhancement_data.empty()) {
        enhancement_reader.emplace(record.enhancement_data,
                                   record.enhancement_bits);
    }
    BitReader* enhancement = enhancement_reader ? &*enhancement_reader : nullptr;
    const unsigned quant_shift = record.quality & 7U;
    const auto [luma_quant, chroma_quant] =
        layered_quant_tables(record.quality);
    const std::size_t chroma_width = width / 2;
    DecodedStripe decoded{
        .stripe_index = record.stripe_index,
        .y = std::vector<std::uint8_t>(16 * width),
        .cb = std::vector<std::uint8_t>(8 * chroma_width),
        .cr = std::vector<std::uint8_t>(8 * chroma_width),
    };
    std::vector<std::uint8_t> base_y(16 * width);
    std::vector<std::uint8_t> base_cb(8 * chroma_width);
    std::vector<std::uint8_t> base_cr(8 * chroma_width);

    const auto reconstruct = [&](std::vector<std::uint8_t>& output_plane,
                                 std::vector<std::uint8_t>& base_plane,
                                 std::size_t plane_width,
                                 std::size_t destination_x,
                                 std::size_t destination_y,
                                 const std::vector<std::int16_t>& predictor,
                                 std::size_t predictor_width,
                                 std::size_t predictor_x,
                                 std::size_t predictor_y,
                                 const CoefficientPair& coefficients,
                                 const QuantTable& quant_table) {
        if (profile == TransformProfile::jpeg_dct) {
            const Block base_residual =
                inverse_dct_block(coefficients.base, quant_table);
            const Block full_residual = enhancement != nullptr
                ? inverse_dct_block(coefficients.full, quant_table)
                : base_residual;
            reconstruct_block(
                base_plane, plane_width, destination_x, destination_y,
                predictor, predictor_width, predictor_x, predictor_y,
                base_residual);
            reconstruct_block(
                output_plane, plane_width, destination_x, destination_y,
                predictor, predictor_width, predictor_x, predictor_y,
                full_residual);
        } else {
            const Block residual =
                inverse_bounded_block(coefficients.full, quant_shift);
            reconstruct_block(
                output_plane, plane_width, destination_x, destination_y,
                predictor, predictor_width, predictor_x, predictor_y,
                residual);
        }
    };

    for (std::size_t luma_x = 0; luma_x < width; luma_x += 16) {
        const std::size_t chroma_x = luma_x / 2;
        const unsigned mode = base_reader.read(2);
        const auto& prediction_y =
            profile == TransformProfile::jpeg_dct ? base_y : decoded.y;
        const auto& prediction_cb =
            profile == TransformProfile::jpeg_dct ? base_cb : decoded.cb;
        const auto& prediction_cr =
            profile == TransformProfile::jpeg_dct ? base_cr : decoded.cr;
        const auto y_predictor =
            make_predictor(prediction_y, width, luma_x, 16, mode);
        const auto cb_predictor =
            make_predictor(prediction_cb, chroma_width, chroma_x, 8, mode);
        const auto cr_predictor =
            make_predictor(prediction_cr, chroma_width, chroma_x, 8, mode);

        for (std::size_t sub_row = 0; sub_row < 2; ++sub_row) {
            for (std::size_t sub_column = 0; sub_column < 2; ++sub_column) {
                const auto coefficients = decode_block_coefficients(
                    base_reader, enhancement, 0, kLumaBaseCount);
                reconstruct(
                    decoded.y, base_y, width,
                    luma_x + sub_column * 8, sub_row * 8,
                    y_predictor, 16, sub_column * 8, sub_row * 8,
                    coefficients, luma_quant);
            }
        }

        for (unsigned plane_index = 0; plane_index < 2; ++plane_index) {
            auto& output_plane = plane_index == 0 ? decoded.cb : decoded.cr;
            auto& base_plane = plane_index == 0 ? base_cb : base_cr;
            const auto& predictor =
                plane_index == 0 ? cb_predictor : cr_predictor;
            const auto coefficients = decode_block_coefficients(
                base_reader, enhancement, 1, kChromaBaseCount);
            reconstruct(
                output_plane, base_plane, chroma_width, chroma_x, 0,
                predictor, 8, 0, 0, coefficients, chroma_quant);
        }
    }

    if (base_reader.position() != base_reader.limit()) {
        fail("unused stripe base-layer bits");
    }
    if (enhancement_reader &&
        enhancement_reader->position() != enhancement_reader->limit()) {
        fail("unused stripe enhancement-layer bits");
    }
    return decoded;
}

struct LayerAssembly {
    bool initialized = false;
    std::uint8_t fragment_count = 0;
    std::uint8_t final_valid_bits = 8;
    std::vector<std::vector<std::uint8_t>> fragments;
    std::vector<bool> present;
};

struct StripeAssembly {
    bool have_quality = false;
    std::uint8_t quality = 24;
    LayerAssembly base;
    LayerAssembly enhancement;
};

void add_fragment(LayerAssembly& layer, std::uint8_t fragment_index,
                  std::uint8_t fragment_count, std::uint8_t final_valid_bits,
                  std::span<const std::uint8_t> payload) {
    if (fragment_count == 0 || fragment_index >= fragment_count) {
        fail("invalid fragment index/count");
    }
    if (!layer.initialized) {
        layer.initialized = true;
        layer.fragment_count = fragment_count;
        layer.fragments.resize(fragment_count);
        layer.present.assign(fragment_count, false);
    } else if (layer.fragment_count != fragment_count) {
        fail("fragment count changed inside one stripe layer");
    }
    if (layer.present[fragment_index]) {
        if (layer.fragments[fragment_index].size() == payload.size() &&
            std::equal(payload.begin(), payload.end(),
                       layer.fragments[fragment_index].begin())) {
            return;
        }
        fail("conflicting duplicate stripe fragment");
    }
    layer.present[fragment_index] = true;
    layer.fragments[fragment_index].assign(payload.begin(), payload.end());
    if (fragment_index + 1 == fragment_count) {
        if (final_valid_bits == 0 || final_valid_bits > 8) {
            fail("invalid final valid-bit count");
        }
        layer.final_valid_bits = final_valid_bits;
    }
}

std::pair<std::vector<std::uint8_t>, std::size_t> finish_layer(
    const LayerAssembly& layer, bool required
) {
    if (!layer.initialized) {
        if (required) {
            fail("stripe is missing its base layer");
        }
        return {};
    }
    if (!std::all_of(layer.present.begin(), layer.present.end(),
                     [](bool present) { return present; })) {
        fail("stripe layer has missing fragments");
    }
    std::size_t total = 0;
    for (const auto& fragment : layer.fragments) {
        total += fragment.size();
    }
    if (total == 0) {
        fail("empty initialized stripe layer");
    }
    std::vector<std::uint8_t> bytes;
    bytes.reserve(total);
    for (const auto& fragment : layer.fragments) {
        bytes.insert(bytes.end(), fragment.begin(), fragment.end());
    }
    const std::size_t bits = (total - 1) * 8 + layer.final_valid_bits;
    return {std::move(bytes), bits};
}

void write_bytes(const std::filesystem::path& path,
                 std::span<const std::uint8_t> bytes) {
    std::ofstream stream(path, std::ios::binary);
    if (!stream || (!bytes.empty() &&
        !stream.write(reinterpret_cast<const char*>(bytes.data()),
                      static_cast<std::streamsize>(bytes.size())))) {
        fail("cannot write output file: " + path.string());
    }
}

std::uint8_t clip_byte(std::int64_t value) {
    return static_cast<std::uint8_t>(std::clamp<std::int64_t>(value, 0, 255));
}

}  // namespace

struct LinkRecordAssembler::Impl {
    struct FrameAssembly {
        bool active = false;
        std::uint16_t display_frame_id = 0;
        std::uint16_t source_frame_id = 0;
        std::uint16_t maximum_record_size = 0;
        std::map<unsigned, StripeAssembly> stripes;
    } frame;

    explicit Impl(std::size_t stripes) : expected_stripes(stripes) {}

    std::size_t expected_stripes;
    std::uint64_t dropped = 0;
    std::uint64_t late = 0;
};

LinkRecordAssembler::LinkRecordAssembler(std::size_t expected_stripes)
    : impl_(std::make_unique<Impl>(expected_stripes)) {
    if (expected_stripes == 0 || expected_stripes > 256) {
        fail("expected stripe count is out of range");
    }
}

LinkRecordAssembler::~LinkRecordAssembler() = default;

std::optional<CapturedFrame> LinkRecordAssembler::push(
    std::span<const std::uint8_t> record
) {
    if (record.size() < 20 || record[0] != kRecordMagic[0] ||
        record[1] != kRecordMagic[1] || record[2] != kRecordMagic[2] ||
        (record[3] != kBaseRecord && record[3] != kEnhancementRecord)) {
        fail("invalid UDP link record signature/type");
    }
    const std::size_t payload_size = read_le16(record, 16);
    if (18 + payload_size + 2 != record.size()) {
        fail("UDP link record payload length mismatch");
    }
    const std::uint16_t expected_crc = read_le16(record, 18 + payload_size);
    if (crc16_ccitt(record.first(18 + payload_size)) != expected_crc) {
        fail("UDP link record CRC16 mismatch");
    }

    const std::uint16_t display_frame_id = read_le16(record, 6);
    const std::uint16_t source_frame_id = read_le16(record, 8);
    std::optional<CapturedFrame> completed;

    const auto finish_active = [&]() -> std::optional<CapturedFrame> {
        auto& frame = impl_->frame;
        if (!frame.active) {
            return std::nullopt;
        }
        const auto layer_complete = [](const LayerAssembly& layer) {
            return layer.initialized &&
                std::all_of(layer.present.begin(), layer.present.end(),
                            [](bool present) { return present; });
        };
        bool enhancement_expected = false;
        for (const auto& [stripe_index, stripe] : frame.stripes) {
            (void)stripe_index;
            enhancement_expected |= stripe.enhancement.initialized;
        }
        bool complete = frame.stripes.size() == impl_->expected_stripes;
        for (std::size_t stripe_index = 0;
             complete && stripe_index < impl_->expected_stripes;
             ++stripe_index) {
            const auto iterator = frame.stripes.find(stripe_index);
            complete = iterator != frame.stripes.end() &&
                       layer_complete(iterator->second.base) &&
                       (!enhancement_expected ||
                        layer_complete(iterator->second.enhancement));
        }
        if (!complete) {
            ++impl_->dropped;
            frame = {};
            return std::nullopt;
        }

        CapturedFrame result{
            .display_frame_id = frame.display_frame_id,
            .source_frame_id = frame.source_frame_id,
            .capture = CaptureFile{
                .expected_yuv_crc32 = 0,
                .maximum_record_size = frame.maximum_record_size,
                .stripes = {},
            },
        };
        result.capture.stripes.reserve(frame.stripes.size());
        for (auto& [stripe_index, stripe] : frame.stripes) {
            auto [base_data, base_bits] = finish_layer(stripe.base, true);
            auto [enhancement_data, enhancement_bits] =
                finish_layer(stripe.enhancement, false);
            result.capture.stripes.push_back(StripeRecord{
                .stripe_index = static_cast<std::uint8_t>(stripe_index),
                .quality = stripe.quality,
                .base_data = std::move(base_data),
                .base_bits = base_bits,
                .enhancement_data = std::move(enhancement_data),
                .enhancement_bits = enhancement_bits,
            });
        }
        frame = {};
        return result;
    };

    auto& frame = impl_->frame;
    if (frame.active && display_frame_id != frame.display_frame_id) {
        const std::uint16_t distance =
            static_cast<std::uint16_t>(display_frame_id - frame.display_frame_id);
        if (distance >= 0x8000U) {
            ++impl_->late;
            return std::nullopt;
        }
        completed = finish_active();
    }
    if (!frame.active) {
        frame.active = true;
        frame.display_frame_id = display_frame_id;
        frame.source_frame_id = source_frame_id;
    } else if (frame.source_frame_id != source_frame_id) {
        fail("source frame ID changed inside UDP frame");
    }

    frame.maximum_record_size = std::max<std::uint16_t>(
        frame.maximum_record_size,
        static_cast<std::uint16_t>(record.size()));
    const std::uint8_t stripe_index = record[10];
    if (stripe_index >= impl_->expected_stripes) {
        fail("UDP stripe index is out of range");
    }
    const std::uint8_t quality = record[11];
    const std::uint8_t fragment_index = record[12];
    const std::uint8_t fragment_count = record[13];
    const std::uint8_t final_valid_bits =
        fragment_index + 1 == fragment_count
        ? static_cast<std::uint8_t>((record[14] & 7U) + 1U) : 8;
    StripeAssembly& stripe = frame.stripes[stripe_index];
    if (stripe.have_quality && stripe.quality != quality) {
        fail("quality changed between UDP stripe fragments");
    }
    stripe.have_quality = true;
    stripe.quality = quality;
    LayerAssembly& layer = record[3] == kBaseRecord
        ? stripe.base : stripe.enhancement;
    add_fragment(layer, fragment_index, fragment_count, final_valid_bits,
                 record.subspan(18, payload_size));
    return completed;
}

std::uint64_t LinkRecordAssembler::dropped_frames() const {
    return impl_->dropped;
}

std::uint64_t LinkRecordAssembler::late_records() const {
    return impl_->late;
}

CaptureFile read_capture_file(const std::filesystem::path& path) {
    const std::vector<std::uint8_t> storage = read_all(path);
    const std::span<const std::uint8_t> bytes(storage);
    if (bytes.size() < 16 ||
        !std::equal(kFileMagic.begin(), kFileMagic.end(), bytes.begin())) {
        fail("input is not an HDZRXT1 capture");
    }
    const std::uint16_t record_count = read_le16(bytes, 8);
    CaptureFile capture{
        .expected_yuv_crc32 = read_le32(bytes, 12),
        .maximum_record_size = read_le16(bytes, 10),
        .stripes = {},
    };
    std::map<unsigned, StripeAssembly> assemblies;
    std::size_t cursor = 16;
    for (unsigned record_index = 0; record_index < record_count; ++record_index) {
        if (cursor + 2 > bytes.size()) {
            fail("capture ended before record length");
        }
        const std::size_t record_size = read_le16(bytes, cursor);
        cursor += 2;
        if (record_size < 20 || record_size > capture.maximum_record_size ||
            cursor + record_size > bytes.size()) {
            fail("invalid capture record size");
        }
        const auto record = bytes.subspan(cursor, record_size);
        cursor += record_size;
        if (record[0] != kRecordMagic[0] || record[1] != kRecordMagic[1] ||
            record[2] != kRecordMagic[2] ||
            (record[3] != kBaseRecord && record[3] != kEnhancementRecord)) {
            fail("invalid link record signature/type");
        }
        const std::size_t payload_size = read_le16(record, 16);
        if (18 + payload_size + 2 != record.size()) {
            fail("link record payload length mismatch");
        }
        const std::uint16_t expected_crc = read_le16(record, 18 + payload_size);
        if (crc16_ccitt(record.first(18 + payload_size)) != expected_crc) {
            fail("link record CRC16 mismatch");
        }
        const std::uint8_t stripe_index = record[10];
        const std::uint8_t quality = record[11];
        const std::uint8_t fragment_index = record[12];
        const std::uint8_t fragment_count = record[13];
        const std::uint8_t final_valid_bits = fragment_index + 1 == fragment_count
            ? static_cast<std::uint8_t>((record[14] & 7U) + 1U)
            : 8;
        StripeAssembly& stripe = assemblies[stripe_index];
        if (stripe.have_quality && stripe.quality != quality) {
            fail("quality changed between stripe fragments");
        }
        stripe.have_quality = true;
        stripe.quality = quality;
        LayerAssembly& layer = record[3] == kBaseRecord
            ? stripe.base : stripe.enhancement;
        add_fragment(layer, fragment_index, fragment_count, final_valid_bits,
                     record.subspan(18, payload_size));
    }
    if (cursor != bytes.size()) {
        fail("trailing bytes after capture records");
    }

    capture.stripes.reserve(assemblies.size());
    for (auto& [stripe_index, assembly] : assemblies) {
        auto [base_data, base_bits] = finish_layer(assembly.base, true);
        auto [enhancement_data, enhancement_bits] =
            finish_layer(assembly.enhancement, false);
        capture.stripes.push_back(StripeRecord{
            .stripe_index = static_cast<std::uint8_t>(stripe_index),
            .quality = assembly.quality,
            .base_data = std::move(base_data),
            .base_bits = base_bits,
            .enhancement_data = std::move(enhancement_data),
            .enhancement_bits = enhancement_bits,
        });
    }
    return capture;
}

std::vector<CapturedFrame> read_capture_frames(
    const std::filesystem::path& path
) {
    const std::vector<std::uint8_t> storage = read_all(path);
    const std::span<const std::uint8_t> bytes(storage);
    if (bytes.size() >= kFileMagic.size() &&
        std::equal(kFileMagic.begin(), kFileMagic.end(), bytes.begin())) {
        return {CapturedFrame{
            .display_frame_id = 0,
            .source_frame_id = 0,
            .capture = read_capture_file(path),
        }};
    }
    if (bytes.size() < 24 ||
        !std::equal(kCaptureMagic.begin(), kCaptureMagic.end(), bytes.begin())) {
        fail("input is neither HDZRXT1 nor HDZCAP1");
    }
    const std::uint32_t version = read_le32(bytes, 8);
    const std::uint32_t record_count = read_le32(bytes, 12);
    const std::uint32_t payload_size = read_le32(bytes, 16);
    const std::uint32_t payload_crc = read_le32(bytes, 20);
    if (version != 1 || payload_size != bytes.size() - 24) {
        fail("invalid HDZCAP1 header");
    }
    if (crc32_update(0, bytes.subspan(24)) != payload_crc) {
        fail("HDZCAP1 payload CRC32 mismatch");
    }

    struct FrameAssembly {
        bool have_source_id = false;
        std::uint16_t source_frame_id = 0;
        std::uint16_t maximum_record_size = 0;
        std::map<unsigned, StripeAssembly> stripes;
    };
    std::map<std::uint16_t, FrameAssembly> frames;
    std::size_t cursor = 24;
    for (std::uint32_t record_index = 0;
         record_index < record_count; ++record_index) {
        if (cursor + 2 > bytes.size()) {
            fail("HDZCAP1 ended before record length");
        }
        const std::size_t record_size = read_le16(bytes, cursor);
        cursor += 2;
        if (record_size < 20 || cursor + record_size > bytes.size()) {
            fail("invalid HDZCAP1 link-record size");
        }
        const auto record = bytes.subspan(cursor, record_size);
        cursor += record_size;
        if (record[0] != kRecordMagic[0] || record[1] != kRecordMagic[1] ||
            record[2] != kRecordMagic[2] ||
            (record[3] != kBaseRecord && record[3] != kEnhancementRecord)) {
            fail("invalid HDZCAP1 link-record signature/type");
        }
        const std::size_t record_payload_size = read_le16(record, 16);
        if (18 + record_payload_size + 2 != record.size()) {
            fail("HDZCAP1 link-record payload length mismatch");
        }
        const std::uint16_t expected_crc =
            read_le16(record, 18 + record_payload_size);
        if (crc16_ccitt(record.first(18 + record_payload_size))
            != expected_crc) {
            fail("HDZCAP1 link-record CRC16 mismatch");
        }

        const std::uint16_t display_frame_id = read_le16(record, 6);
        const std::uint16_t source_frame_id = read_le16(record, 8);
        FrameAssembly& frame = frames[display_frame_id];
        if (frame.have_source_id &&
            frame.source_frame_id != source_frame_id) {
            fail("source frame ID changed within a display frame");
        }
        frame.have_source_id = true;
        frame.source_frame_id = source_frame_id;
        frame.maximum_record_size = std::max<std::uint16_t>(
            frame.maximum_record_size,
            static_cast<std::uint16_t>(record_size));

        const std::uint8_t stripe_index = record[10];
        const std::uint8_t quality = record[11];
        const std::uint8_t fragment_index = record[12];
        const std::uint8_t fragment_count = record[13];
        const std::uint8_t final_valid_bits =
            fragment_index + 1 == fragment_count
            ? static_cast<std::uint8_t>((record[14] & 7U) + 1U) : 8;
        StripeAssembly& stripe = frame.stripes[stripe_index];
        if (stripe.have_quality && stripe.quality != quality) {
            fail("quality changed between HDZCAP1 stripe fragments");
        }
        stripe.have_quality = true;
        stripe.quality = quality;
        LayerAssembly& layer = record[3] == kBaseRecord
            ? stripe.base : stripe.enhancement;
        add_fragment(layer, fragment_index, fragment_count,
                     final_valid_bits,
                     record.subspan(18, record_payload_size));
    }
    if (cursor != bytes.size()) {
        fail("trailing bytes after HDZCAP1 records");
    }

    const auto layer_complete = [](const LayerAssembly& layer,
                                   bool required) {
        if (!layer.initialized) {
            return !required;
        }
        return std::all_of(layer.present.begin(), layer.present.end(),
                           [](bool present) { return present; });
    };
    std::vector<CapturedFrame> result;
    result.reserve(frames.size());
    for (auto& [frame_id, assembly] : frames) {

        CapturedFrame captured{
            .display_frame_id = frame_id,
            .source_frame_id = assembly.source_frame_id,
            .capture = CaptureFile{
                .expected_yuv_crc32 = 0,
                .maximum_record_size = assembly.maximum_record_size,
                .stripes = {},
            },
        };
        captured.capture.stripes.reserve(assembly.stripes.size());
        for (auto& [stripe_index, stripe] : assembly.stripes) {
            if (!layer_complete(stripe.base, true) ||
                !layer_complete(stripe.enhancement, false)) {
                continue;
            }
            auto [base_data, base_bits] = finish_layer(stripe.base, true);
            auto [enhancement_data, enhancement_bits] =
                finish_layer(stripe.enhancement, false);
            captured.capture.stripes.push_back(StripeRecord{
                .stripe_index = static_cast<std::uint8_t>(stripe_index),
                .quality = stripe.quality,
                .base_data = std::move(base_data),
                .base_bits = base_bits,
                .enhancement_data = std::move(enhancement_data),
                .enhancement_bits = enhancement_bits,
            });
        }
        if (!captured.capture.stripes.empty()) {
            result.push_back(std::move(captured));
        }
    }
    return result;
}

Frame decode_frame(const CaptureFile& capture,
                   const DecodeOptions& options,
                   DecodeStats* stats) {
    if (options.width == 0 || options.width % 16 != 0 ||
        options.height == 0 || options.height % 16 != 0) {
        fail("frame dimensions must be positive multiples of 16");
    }
    if (capture.stripes.size() > options.height / kStripeHeight ||
        (!options.allow_partial &&
         capture.stripes.size() != options.height / kStripeHeight)) {
        fail("capture stripe count does not match requested frame height");
    }
    std::vector<DecodedStripe> decoded(capture.stripes.size());
    std::atomic_size_t next{0};
    std::exception_ptr worker_error;
    std::mutex error_mutex;
    unsigned thread_count = options.threads;
    if (thread_count == 0) {
        thread_count = std::max(1U, std::thread::hardware_concurrency());
    }
    thread_count = std::min<unsigned>(
        thread_count, static_cast<unsigned>(capture.stripes.size())
    );

    const auto started = std::chrono::steady_clock::now();
    std::vector<std::thread> workers;
    workers.reserve(thread_count);
    for (unsigned worker = 0; worker < thread_count; ++worker) {
        workers.emplace_back([&] {
            try {
                for (;;) {
                    const std::size_t index = next.fetch_add(1);
                    if (index >= capture.stripes.size()) {
                        break;
                    }
                    try {
                        decoded[index] = decode_stripe(
                            capture.stripes[index], options.width,
                            options.profile);
                    } catch (const std::exception& error) {
                        fail("stripe " + std::to_string(
                            capture.stripes[index].stripe_index) + ": " +
                            error.what());
                    }
                }
            } catch (...) {
                std::lock_guard lock(error_mutex);
                if (!worker_error) {
                    worker_error = std::current_exception();
                }
                next.store(capture.stripes.size());
            }
        });
    }
    for (auto& worker : workers) {
        worker.join();
    }
    if (worker_error) {
        std::rethrow_exception(worker_error);
    }
    const auto stopped = std::chrono::steady_clock::now();

    Frame frame{
        .width = options.width,
        .height = options.height,
        .y = std::vector<std::uint8_t>(options.width * options.height, 128),
        .cb = std::vector<std::uint8_t>(options.width * options.height / 4, 128),
        .cr = std::vector<std::uint8_t>(options.width * options.height / 4, 128),
    };
    std::vector<bool> stripe_present(options.height / 16, false);
    for (const auto& stripe : decoded) {
        if (stripe.stripe_index >= stripe_present.size() ||
            stripe_present[stripe.stripe_index]) {
            fail("duplicate or out-of-range decoded stripe index");
        }
        stripe_present[stripe.stripe_index] = true;
        const std::size_t y_offset = stripe.stripe_index * 16 * options.width;
        std::copy(stripe.y.begin(), stripe.y.end(), frame.y.begin() + y_offset);
        const std::size_t chroma_offset = stripe.stripe_index * 8 * (options.width / 2);
        std::copy(stripe.cb.begin(), stripe.cb.end(), frame.cb.begin() + chroma_offset);
        std::copy(stripe.cr.begin(), stripe.cr.end(), frame.cr.begin() + chroma_offset);
    }
    if (!options.allow_partial &&
        !std::all_of(stripe_present.begin(), stripe_present.end(),
                     [](bool present) { return present; })) {
        fail("decoded frame has missing stripe indices");
    }

    if (stats != nullptr) {
        stats->stripe_count = capture.stripes.size();
        stats->base_bytes = 0;
        stats->enhancement_bytes = 0;
        for (const auto& stripe : capture.stripes) {
            stats->base_bytes += stripe.base_data.size();
            stats->enhancement_bytes += stripe.enhancement_data.size();
        }
        stats->milliseconds = std::chrono::duration<double, std::milli>(
            stopped - started
        ).count();
    }
    return frame;
}

std::uint32_t frame_crc32(const Frame& frame) {
    std::uint32_t crc = crc32_update(0, frame.y);
    crc = crc32_update(crc, frame.cb);
    return crc32_update(crc, frame.cr);
}

void write_yuv420(const std::filesystem::path& path, const Frame& frame) {
    std::vector<std::uint8_t> bytes;
    bytes.reserve(frame.y.size() + frame.cb.size() + frame.cr.size());
    bytes.insert(bytes.end(), frame.y.begin(), frame.y.end());
    bytes.insert(bytes.end(), frame.cb.begin(), frame.cb.end());
    bytes.insert(bytes.end(), frame.cr.begin(), frame.cr.end());
    write_bytes(path, bytes);
}

void write_ppm(const std::filesystem::path& path, const Frame& frame) {
    std::ofstream stream(path, std::ios::binary);
    if (!stream) {
        fail("cannot open PPM output: " + path.string());
    }
    stream << "P6\n" << frame.width << ' ' << frame.height << "\n255\n";
    std::array<std::uint8_t, 3> rgb{};
    for (std::size_t row = 0; row < frame.height; ++row) {
        for (std::size_t column = 0; column < frame.width; ++column) {
            const std::int64_t y = frame.y[row * frame.width + column];
            const std::size_t chroma_index =
                (row / 2) * (frame.width / 2) + column / 2;
            const std::int64_t cb = frame.cb[chroma_index] - 128;
            const std::int64_t cr = frame.cr[chroma_index] - 128;
            rgb[0] = clip_byte(y + floor_shift(359 * cr + 128, 8));
            rgb[1] = clip_byte(y - floor_shift(88 * cb + 183 * cr + 128, 8));
            rgb[2] = clip_byte(y + floor_shift(454 * cb + 128, 8));
            stream.write(reinterpret_cast<const char*>(rgb.data()), 3);
        }
    }
    if (!stream) {
        fail("cannot write PPM output: " + path.string());
    }
}

}  // namespace hdzero
