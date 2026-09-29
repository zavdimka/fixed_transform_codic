#include "hdzero/raw_monitor.hpp"

#include <algorithm>
#include <arpa/inet.h>
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <iterator>
#include <linux/if_packet.h>
#include <net/ethernet.h>
#include <net/if.h>
#include <net/if_arp.h>
#include <stdexcept>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>

namespace hdzero {
namespace {

constexpr std::uint8_t link_bssid[] = {
    0x02, 0x46, 0x50, 0x56, 0x00, 0x01,
};
constexpr std::size_t radiotap_minimum_size = 8;
constexpr std::size_t ieee80211_header_size = 24;
constexpr std::size_t link_header_size = ieee80211_header_size + 2;

std::uint16_t read_le16(const std::uint8_t* data) {
    return static_cast<std::uint16_t>(data[0]) |
           (static_cast<std::uint16_t>(data[1]) << 8);
}

bool valid_record(std::span<const std::uint8_t> record) {
    return record.size() >= 20 &&
           record[0] == 0xc5 && record[1] == 0x3a && record[2] == 0x01 &&
           20u + read_le16(record.data() + 16) == record.size();
}

std::optional<std::size_t> transport_payload_size(
    std::span<const std::uint8_t> payload) {
    if (payload.size() >= 4 && payload[0] == 'H' && payload[1] == 'Z' &&
        payload[2] == 'U' && payload[3] == 1) {
        std::size_t cursor = 4;
        std::size_t records = 0;
        while (cursor + 2 <= payload.size()) {
            if (records != 0 && payload.size() - cursor == 4) {
                return cursor;
            }
            const std::size_t length = read_le16(payload.data() + cursor);
            cursor += 2;
            if (length < 20 || cursor + length > payload.size() ||
                !valid_record(payload.subspan(cursor, length))) {
                return std::nullopt;
            }
            cursor += length;
            ++records;
            if (cursor == payload.size() || payload.size() - cursor == 4) {
                return cursor;
            }
        }
        return std::nullopt;
    }

    if (payload.size() < 20 || payload[0] != 0xc5 ||
        payload[1] != 0x3a || payload[2] != 0x01) {
        return std::nullopt;
    }
    const std::size_t length = 20u + read_le16(payload.data() + 16);
    if (length > payload.size() || !valid_record(payload.first(length))) {
        return std::nullopt;
    }
    return length;
}

[[noreturn]] void throw_system_error(const std::string& operation) {
    throw std::runtime_error(operation + ": " + std::strerror(errno));
}

}  // namespace

std::optional<std::span<const std::uint8_t>> extract_monitor_payload(
    std::span<const std::uint8_t> packet) {
    if (packet.size() < radiotap_minimum_size || packet[0] != 0) {
        return std::nullopt;
    }
    const std::size_t radiotap_size = read_le16(packet.data() + 2);
    if (radiotap_size < radiotap_minimum_size ||
        radiotap_size > packet.size()) {
        return std::nullopt;
    }

    const auto frame = packet.subspan(radiotap_size);
    if (frame.size() < link_header_size) {
        return std::nullopt;
    }
    const std::uint16_t frame_control = read_le16(frame.data());
    if ((frame_control & 0x00fcu) != 0x0008u ||
        (frame_control & 0x0300u) != 0 ||
        !std::equal(std::begin(link_bssid), std::end(link_bssid),
                    frame.begin() + 16) ||
        frame[24] != 0x88 || frame[25] != 0xb5) {
        return std::nullopt;
    }

    const auto payload = frame.subspan(link_header_size);
    const auto length = transport_payload_size(payload);
    if (!length) {
        return std::nullopt;
    }
    return payload.first(*length);
}

int open_monitor_interface(const std::string& interface_name) {
    const unsigned interface_index = if_nametoindex(interface_name.c_str());
    if (interface_index == 0) {
        throw_system_error("unknown monitor interface " + interface_name);
    }

    const int fd = ::socket(AF_PACKET, SOCK_RAW | SOCK_NONBLOCK,
                            htons(ETH_P_ALL));
    if (fd < 0) {
        throw_system_error("AF_PACKET socket failed");
    }

    ifreq request{};
    std::strncpy(request.ifr_name, interface_name.c_str(), IFNAMSIZ - 1);
    if (::ioctl(fd, SIOCGIFHWADDR, &request) < 0) {
        const int saved_errno = errno;
        ::close(fd);
        errno = saved_errno;
        throw_system_error("could not inspect " + interface_name);
    }
    if (request.ifr_hwaddr.sa_family != ARPHRD_IEEE80211_RADIOTAP) {
        ::close(fd);
        throw std::runtime_error(
            interface_name +
            " is not a radiotap monitor interface; configure it with iw");
    }

    int receive_buffer = 8 * 1024 * 1024;
    (void)::setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receive_buffer,
                       sizeof(receive_buffer));
    sockaddr_ll address{};
    address.sll_family = AF_PACKET;
    address.sll_protocol = htons(ETH_P_ALL);
    address.sll_ifindex = static_cast<int>(interface_index);
    if (::bind(fd, reinterpret_cast<const sockaddr*>(&address),
               sizeof(address)) < 0) {
        const int saved_errno = errno;
        ::close(fd);
        errno = saved_errno;
        throw_system_error("monitor bind failed");
    }
    return fd;
}

}  // namespace hdzero
