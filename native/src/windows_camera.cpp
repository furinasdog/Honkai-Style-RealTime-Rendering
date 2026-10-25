#include "windows_camera.hpp"
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mferror.h>
#include <wrl/client.h>
#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <mutex>

using Microsoft::WRL::ComPtr;
namespace mocap {
static constexpr DWORD video_stream = static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM);
struct WindowsCamera::State {
    std::mutex mutex;
    std::condition_variable changed;
    ComPtr<IMFMediaSource> source;
    ComPtr<IMFSourceReader> reader;
    CameraFrame latest;
    std::string error;
    int width = 0;
    int height = 0;
    LONG stride = 0;
    bool ready = false;
    bool closed = false;
    void fail(const char* operation, HRESULT code) {
        char message[160];
        std::snprintf(message, sizeof(message), "%s (0x%08lX)", operation, static_cast<unsigned long>(code));
        std::lock_guard<std::mutex> lock(mutex);
        error = message;
        changed.notify_all();
    }
};

struct WindowsCamera::ReaderCallback final : IMFSourceReaderCallback {
    std::atomic<ULONG> references{1};
    std::weak_ptr<State> target;
    explicit ReaderCallback(const std::shared_ptr<State>& value) : target(value) {}
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id, void** value) override {
        if (!value) return E_POINTER;
        if (id == IID_IUnknown || id == __uuidof(IMFSourceReaderCallback)) {
            *value = static_cast<IMFSourceReaderCallback*>(this); AddRef(); return S_OK;
        }
        *value = nullptr; return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++references; }
    ULONG STDMETHODCALLTYPE Release() override {
        const auto count = --references;
        if (!count) delete this;
        return count;
    }
    HRESULT STDMETHODCALLTYPE OnEvent(DWORD, IMFMediaEvent*) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE OnFlush(DWORD) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE OnReadSample(HRESULT status, DWORD, DWORD flags, LONGLONG, IMFSample* sample) override {
        auto state = target.lock();
        if (!state) return S_OK;
        ComPtr<IMFSourceReader> reader;
        {
            std::lock_guard<std::mutex> lock(state->mutex);
            if (state->closed) return S_OK;
            reader = state->reader;
        }
        if (FAILED(status) || (flags & MF_SOURCE_READERF_ENDOFSTREAM)) {
            state->fail("Camera stream ended", FAILED(status) ? status : MF_E_END_OF_STREAM);
            return S_OK;
        }
        if (sample) {
            ComPtr<IMFMediaBuffer> buffer;
            status = sample->ConvertToContiguousBuffer(&buffer);
            if (FAILED(status)) { state->fail("Cannot access camera frame", status); return S_OK; }
            BYTE* data = nullptr;
            LONG stride = state->stride;
            ComPtr<IMF2DBuffer> buffer2d;
            bool locked2d = SUCCEEDED(buffer.As(&buffer2d)) && SUCCEEDED(buffer2d->Lock2D(&data, &stride));
            DWORD length = 0;
            if (!locked2d) {
                status = buffer->Lock(&data, nullptr, &length);
                if (FAILED(status)) { state->fail("Cannot lock camera frame", status); return S_OK; }
                const auto needed = static_cast<std::uint64_t>(std::abs(stride)) * state->height;
                if (length < needed) { buffer->Unlock(); state->fail("Truncated camera frame", E_FAIL); return S_OK; }
                if (stride < 0) data += static_cast<std::size_t>(-stride) * (state->height - 1);
            }
            const double scale = std::min({1.0, 640.0 / state->width, 480.0 / state->height});
            CameraFrame frame;
            frame.width = std::max(1, static_cast<int>(state->width * scale));
            frame.height = std::max(1, static_cast<int>(state->height * scale));
            frame.rgb.resize(static_cast<std::size_t>(frame.width) * frame.height * 3);
            for (int y = 0; y < frame.height; ++y) {
                const auto* row = data + static_cast<std::ptrdiff_t>(y * state->height / frame.height) * stride;
                for (int x = 0; x < frame.width; ++x) {
                    const auto* pixel = row + (x * state->width / frame.width) * 4;
                    auto* destination = frame.rgb.data() + (static_cast<std::size_t>(y) * frame.width + x) * 3;
                    destination[0] = pixel[2]; destination[1] = pixel[1]; destination[2] = pixel[0];
                }
            }
            if (locked2d) buffer2d->Unlock2D(); else buffer->Unlock();
            {
                std::lock_guard<std::mutex> lock(state->mutex);
                if (state->closed) return S_OK;
                // Keep only the newest frame; slow inference must not build a latency queue.
                state->latest = std::move(frame);
                state->ready = true;
            }
            state->changed.notify_one();
        }
        {
            std::lock_guard<std::mutex> lock(state->mutex);
            if (state->closed) return S_OK;
        }
        if (reader) {
            status = reader->ReadSample(video_stream, 0, nullptr, nullptr, nullptr, nullptr);
            if (FAILED(status)) state->fail("Cannot request camera frame", status);
        }
        return S_OK;
    }
};

WindowsCamera::WindowsCamera() : state(std::make_shared<State>()) {}
WindowsCamera::~WindowsCamera() { close(); }
void WindowsCamera::close() {
    cancel();
    ComPtr<IMFSourceReader> reader;
    ComPtr<IMFMediaSource> source;
    { std::lock_guard<std::mutex> lock(state->mutex); reader.Swap(state->reader); source.Swap(state->source); }
    reader.Reset(); source.Reset();
    if (media_foundation_started) { MFShutdown(); media_foundation_started = false; }
}

bool WindowsCamera::open(int device, int width, int height, int fps) {
    auto check = [this](HRESULT code, const char* operation) {
        if (FAILED(code)) { state->fail(operation, code); return false; }
        return true;
    };
    if (!check(MFStartup(MF_VERSION), "Cannot initialize Windows camera service")) return false;
    media_foundation_started = true;
    ComPtr<IMFAttributes> attributes;
    if (!check(MFCreateAttributes(&attributes, 3), "Cannot create camera attributes")) return false;
    attributes->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);
    IMFActivate** devices = nullptr;
    UINT count = 0;
    if (!check(MFEnumDeviceSources(attributes.Get(), &devices, &count), "Cannot enumerate cameras")) return false;
    ComPtr<IMFMediaSource> source;
    HRESULT activation = E_INVALIDARG;
    if (device >= 0 && static_cast<UINT>(device) < count) activation = devices[device]->ActivateObject(IID_PPV_ARGS(&source));
    for (UINT index = 0; index < count; ++index) devices[index]->Release();
    CoTaskMemFree(devices);
    if (!check(activation, "Cannot open selected camera; check device number and access")) return false;
    bool closed = false;
    {
        std::lock_guard<std::mutex> lock(state->mutex);
        state->source = source;
        closed = state->closed;
    }
    if (closed) { source->Shutdown(); return false; }
    ComPtr<ReaderCallback> callback;
    callback.Attach(new ReaderCallback(state));
    attributes.Reset();
    if (!check(MFCreateAttributes(&attributes, 3), "Cannot create reader attributes")) return false;
    attributes->SetUnknown(MF_SOURCE_READER_ASYNC_CALLBACK, callback.Get());
    // Enabling both processors makes reader creation fail with E_INVALIDARG.
    attributes->SetUINT32(MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, FALSE);
    attributes->SetUINT32(MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING, TRUE);
    ComPtr<IMFSourceReader> reader;
    if (!check(MFCreateSourceReaderFromMediaSource(source.Get(), attributes.Get(), &reader), "Cannot create camera reader")) return false;
    ComPtr<IMFMediaType> type;
    if (!check(MFCreateMediaType(&type), "Cannot create camera format")) return false;
    type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
    MFSetAttributeSize(type.Get(), MF_MT_FRAME_SIZE, width, height);
    MFSetAttributeRatio(type.Get(), MF_MT_FRAME_RATE, fps, 1);
    if (FAILED(reader->SetCurrentMediaType(video_stream, nullptr, type.Get()))) {
        type->DeleteItem(MF_MT_FRAME_SIZE); type->DeleteItem(MF_MT_FRAME_RATE);
        if (!check(reader->SetCurrentMediaType(video_stream, nullptr, type.Get()), "Camera cannot produce RGB frames")) return false;
    }
    if (!check(reader->GetCurrentMediaType(video_stream, &type), "Cannot query camera resolution")) return false;
    UINT32 actual_width = 0, actual_height = 0;
    if (!check(MFGetAttributeSize(type.Get(), MF_MT_FRAME_SIZE, &actual_width, &actual_height), "Missing camera resolution")) return false;
    if (!actual_width || !actual_height || actual_width > 8192 || actual_height > 8192) { state->fail("Invalid camera resolution", E_INVALIDARG); return false; }
    LONG stride = static_cast<LONG>(actual_width * 4);
    UINT32 raw_stride = 0;
    if (SUCCEEDED(type->GetUINT32(MF_MT_DEFAULT_STRIDE, &raw_stride))) stride = static_cast<LONG>(raw_stride);
    {
        std::lock_guard<std::mutex> lock(state->mutex);
        closed = state->closed;
        state->width = static_cast<int>(actual_width); state->height = static_cast<int>(actual_height);
        state->stride = stride; state->reader = reader;
    }
    if (closed) { source->Shutdown(); return false; }
    return check(reader->ReadSample(video_stream, 0, nullptr, nullptr, nullptr, nullptr), "Cannot start camera stream");
}

bool WindowsCamera::next(CameraFrame& frame, const std::atomic<bool>& running) {
    std::unique_lock<std::mutex> lock(state->mutex);
    state->changed.wait_for(lock, std::chrono::milliseconds(200), [&] { return state->ready || state->closed || !state->error.empty() || !running.load(); });
    if (!state->ready || state->closed || !running.load()) return false;
    frame = std::move(state->latest);
    state->ready = false;
    return true;
}

void WindowsCamera::cancel() {
    ComPtr<IMFSourceReader> reader;
    ComPtr<IMFMediaSource> source;
    {
        std::lock_guard<std::mutex> lock(state->mutex);
        if (state->closed) return;
        state->closed = true;
        reader = state->reader; source = state->source;
    }
    state->changed.notify_all();
    if (reader) reader->Flush(video_stream);
    if (source) source->Shutdown();
}

std::string WindowsCamera::error() const {
    std::lock_guard<std::mutex> lock(state->mutex);
    return state->error;
}
}
