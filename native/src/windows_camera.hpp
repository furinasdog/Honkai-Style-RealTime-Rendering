#pragma once
#include <atomic>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace mocap {
struct CameraFrame {
    int width = 0;
    int height = 0;
    std::vector<std::uint8_t> rgb;
};

class WindowsCamera {
public:
    WindowsCamera();
    ~WindowsCamera();
    bool open(int device, int width, int height, int fps);
    bool next(CameraFrame& frame, const std::atomic<bool>& running);
    void cancel();
    void close();
    std::string error() const;
private:
    struct State;
    struct ReaderCallback;
    std::shared_ptr<State> state;
    bool media_foundation_started = false;
};
}
