#pragma once
#include <array>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace mocap {
constexpr std::size_t frame_size = 590;
struct Frame {
    // flags[4], pose world[132], pose image[132], two hands[127], face[52], row-major matrix[16].
    std::array<float, frame_size> values{};
    std::vector<float> face_image;
    std::int64_t timestamp_ms = 0;
    std::int64_t sequence = 0;
};

class Tracker {
public:
    Tracker();
    ~Tracker();
    Tracker(const Tracker&) = delete;
    Tracker& operator=(const Tracker&) = delete;
    bool initialize(const std::wstring& library, const std::array<std::vector<std::uint8_t>, 3>& models);
    bool detect(const std::uint8_t* rgb, int width, int height, std::int64_t timestamp_ms, Frame& output);
    void close();
    const std::string& error() const;
private:
    struct Impl;
    std::unique_ptr<Impl> impl;
};
}
