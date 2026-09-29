#include "hdzero/raw_monitor.hpp"

#include <algorithm>
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <vector>

namespace {

void expect(bool condition, const char* message) {
    if (!condition) {
        throw std::runtime_error(message);
    }
}

std::vector<std::uint8_t> make_record() {
    std::vector<std::uint8_t> record(20, 0);
    record[0] = 0xc5;
    record[1] = 0x3a;
    record[2] = 0x01;
    return record;
}

std::vector<std::uint8_t> wrap_monitor_frame(
    const std::vector<std::uint8_t>& payload, bool add_fcs) {
    std::vector<std::uint8_t> packet = {
        0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x08, 0x00, 0x00, 0x00,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0x10, 0xbd, 0xa3, 0xd7, 0x43, 0x18,
        0x02, 0x46, 0x50, 0x56, 0x00, 0x01,
        0x10, 0x00, 0x88, 0xb5,
    };
    packet.insert(packet.end(), payload.begin(), payload.end());
    if (add_fcs) {
        packet.insert(packet.end(), {0xde, 0xad, 0xbe, 0xef});
    }
    return packet;
}

}  // namespace

int main() {
    const auto record = make_record();
    std::vector<std::uint8_t> batch = {'H', 'Z', 'U', 1, 20, 0};
    batch.insert(batch.end(), record.begin(), record.end());

    auto packet = wrap_monitor_frame(batch, true);
    auto extracted = hdzero::extract_monitor_payload(packet);
    expect(extracted.has_value(), "valid radiotap frame was rejected");
    expect(extracted->size() == batch.size(), "FCS was not trimmed");
    expect(std::equal(extracted->begin(), extracted->end(), batch.begin()),
           "aggregated payload changed");

    packet = wrap_monitor_frame(record, false);
    extracted = hdzero::extract_monitor_payload(packet);
    expect(extracted.has_value() && extracted->size() == record.size(),
           "bare link record was rejected");

    packet[32] = 0x89;
    expect(!hdzero::extract_monitor_payload(packet).has_value(),
           "foreign EtherType was accepted");

    packet = wrap_monitor_frame(batch, false);
    packet[2] = 0xff;
    packet[3] = 0x7f;
    expect(!hdzero::extract_monitor_payload(packet).has_value(),
           "invalid radiotap length was accepted");

    std::cout << "raw monitor parser tests passed\n";
    return 0;
}
