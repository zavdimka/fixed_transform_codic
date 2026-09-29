#pragma once

#include <cstdint>
#include <optional>
#include <span>
#include <string>

namespace hdzero {

std::optional<std::span<const std::uint8_t>> extract_monitor_payload(
    std::span<const std::uint8_t> packet);

int open_monitor_interface(const std::string& interface_name);

}  // namespace hdzero
