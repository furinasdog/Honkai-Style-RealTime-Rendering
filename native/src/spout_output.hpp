#pragma once
#include <cstdint>
#include <memory>
#include <string>

namespace mocap {
class SpoutOutput {
public:
    SpoutOutput();
    ~SpoutOutput();
    std::uint64_t create(std::uint64_t device, std::uint64_t queue, int width, int height);
    bool send();
    void close();
    std::string sender_name() const;
private:
    struct Impl;
    std::unique_ptr<Impl> impl;
};
}
