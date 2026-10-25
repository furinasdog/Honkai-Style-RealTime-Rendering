#include "gdextension_interface.h"
#include "api_sizes.hpp"
#include "mediapipe_core.hpp"
#include "windows_camera.hpp"
#include "archive_service.hpp"
#include "spout_output.hpp"
#include "mmd_pmx.h"
#include <windows.h>
#include <objbase.h>
#include <array>
#include <atomic>
#include <chrono>
#include <cstring>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <thread>
#include <vector>
#include <fstream>
#include <unordered_map>
#include <unordered_set>
#include <algorithm>
#include <cmath>
#include <functional>
#include <limits>

namespace {
GDExtensionClassLibraryPtr class_library;
HMODULE native_module;
struct API {
    GDExtensionInterfaceVariantNewNil nil;
    GDExtensionInterfaceVariantNewCopy copy;
    GDExtensionInterfaceVariantDestroy destroy;
    GDExtensionInterfaceVariantGetType type;
    GDExtensionInterfaceVariantConstruct construct;
    GDExtensionInterfaceVariantCall call;
    GDExtensionInterfaceVariantGetIndexed indexed;
    GDExtensionInterfaceGetVariantFromTypeConstructor from;
    GDExtensionInterfaceGetVariantToTypeConstructor to;
    GDExtensionInterfaceVariantGetPtrDestructor destructor;
    GDExtensionInterfaceStringNameNewWithUtf8Chars name;
    GDExtensionInterfaceStringNewWithUtf8Chars string;
    GDExtensionInterfaceStringToUtf8Chars utf8;
    GDExtensionInterfacePackedByteArrayOperatorIndexConst bytes;
    GDExtensionInterfacePackedByteArrayOperatorIndex writable_bytes;
    GDExtensionInterfacePackedFloat32ArrayOperatorIndex floats;
    GDExtensionInterfacePackedVector3ArrayOperatorIndex vectors;
    GDExtensionInterfacePackedVector2ArrayOperatorIndex uvs;
    GDExtensionInterfacePackedColorArrayOperatorIndex colors;
    GDExtensionInterfacePackedInt32ArrayOperatorIndex ints;
    GDExtensionInterfaceClassdbRegisterExtensionClass6 register_class;
    GDExtensionInterfaceClassdbUnregisterExtensionClass unregister_class;
    GDExtensionInterfaceClassdbRegisterExtensionClassMethod register_method;
    GDExtensionInterfaceClassdbConstructObject3 object;
    GDExtensionInterfaceObjectSetInstance instance;
} api;

struct Name {
    alignas(16) std::byte data[gdabi::string_name_size];
    explicit Name(const char* value) { api.name(data, value); }
    ~Name() { api.destructor(GDEXTENSION_VARIANT_TYPE_STRING_NAME)(data); }
};

struct Value {
    alignas(16) std::byte data[gdabi::variant_size];
    Value() { api.nil(data); }
    explicit Value(GDExtensionConstVariantPtr value) { api.copy(data, value); }
    Value(const Value& value) { api.copy(data, value.data); }
    ~Value() { api.destroy(data); }
    Value& operator=(const Value& value) {
        if (this != &value) { api.destroy(data); api.copy(data, value.data); }
        return *this;
    }
    static Value integer(std::int64_t value) {
        Value result; api.destroy(result.data); api.from(GDEXTENSION_VARIANT_TYPE_INT)(result.data, &value); return result;
    }
    static Value number(double value) {
        Value result; api.destroy(result.data); api.from(GDEXTENSION_VARIANT_TYPE_FLOAT)(result.data, &value); return result;
    }
    static Value boolean(bool value) {
        GDExtensionBool native = value;
        Value result; api.destroy(result.data); api.from(GDEXTENSION_VARIANT_TYPE_BOOL)(result.data, &native); return result;
    }
    static Value text(const std::string& value) {
        alignas(16) std::byte string[gdabi::string_size]; api.string(string, value.c_str());
        Value result; api.destroy(result.data); api.from(GDEXTENSION_VARIANT_TYPE_STRING)(result.data, string);
        api.destructor(GDEXTENSION_VARIANT_TYPE_STRING)(string); return result;
    }
    static Value object(GDExtensionObjectPtr object) {
        Value result; api.destroy(result.data); api.from(GDEXTENSION_VARIANT_TYPE_OBJECT)(result.data, &object); return result;
    }
    Value invoke(const char* method, const std::vector<Value>& arguments = {}) {
        std::vector<GDExtensionConstVariantPtr> pointers;
        for (const auto& argument : arguments) pointers.push_back(argument.data);
        Name name(method); Value result; api.destroy(result.data);
        GDExtensionCallError error{};
        api.call(data, name.data, pointers.data(), static_cast<GDExtensionInt>(pointers.size()), result.data, &error);
        if (error.error != GDEXTENSION_CALL_OK) throw std::runtime_error(std::string("Godot API call failed: ") + method);
        return result;
    }
    std::int64_t integer() const {
        if (api.type(data) != GDEXTENSION_VARIANT_TYPE_INT) throw std::invalid_argument("Expected an integer");
        std::int64_t result = 0; api.to(GDEXTENSION_VARIANT_TYPE_INT)(&result, const_cast<std::byte*>(data)); return result;
    }
    std::string text() const {
        if (api.type(data) != GDEXTENSION_VARIANT_TYPE_STRING) throw std::invalid_argument("Expected a String");
        alignas(16) std::byte string[gdabi::string_size];
        api.to(GDEXTENSION_VARIANT_TYPE_STRING)(string, const_cast<std::byte*>(data));
        auto size = api.utf8(string, nullptr, 0);
        std::string result(static_cast<std::size_t>(size), '\0');
        if (size) api.utf8(string, result.data(), size);
        api.destructor(GDEXTENSION_VARIANT_TYPE_STRING)(string);
        return result;
    }
    std::vector<std::uint8_t> bytes() {
        if (api.type(data) != GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY) throw std::invalid_argument("Expected a PackedByteArray");
        auto size = invoke("size").integer();
        if (size < 0 || size > 128 * 1024 * 1024) throw std::invalid_argument("Byte buffer is too large");
        if (!size) return {};
        alignas(16) std::byte packed[gdabi::packed_bytes_size];
        api.to(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY)(packed, data);
        const auto* source = api.bytes(packed, 0);
        std::vector<std::uint8_t> result(source, source + size);
        api.destructor(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY)(packed);
        return result;
    }
    Value at(int index) {
        Value result; api.destroy(result.data); GDExtensionBool valid = false, out_of_bounds = false;
        api.indexed(data, index, result.data, &valid, &out_of_bounds);
        if (!valid || out_of_bounds) throw std::invalid_argument("Invalid array index");
        return result;
    }
    static Value floats(const float* values, std::size_t count) {
        Value result; api.destroy(result.data); GDExtensionCallError error{};
        api.construct(GDEXTENSION_VARIANT_TYPE_PACKED_FLOAT32_ARRAY, result.data, nullptr, 0, &error);
        result.invoke("resize", {Value::integer(count)});
        alignas(16) std::byte packed[gdabi::packed_floats_size];
        api.to(GDEXTENSION_VARIANT_TYPE_PACKED_FLOAT32_ARRAY)(packed, result.data);
        if (count) std::memcpy(api.floats(packed, 0), values, count * sizeof(float));
        api.destroy(result.data);
        api.from(GDEXTENSION_VARIANT_TYPE_PACKED_FLOAT32_ARRAY)(result.data, packed);
        api.destructor(GDEXTENSION_VARIANT_TYPE_PACKED_FLOAT32_ARRAY)(packed);
        return result;
    }
    static Value frame(const mocap::Frame& frame) { return floats(frame.values.data(), frame.values.size()); }
    static Value bytes(const std::vector<std::uint8_t>& values) {
        Value result; api.destroy(result.data); GDExtensionCallError error{};
        api.construct(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY, result.data, nullptr, 0, &error);
        result.invoke("resize", {Value::integer(values.size())});
        alignas(16) std::byte packed[gdabi::packed_bytes_size];
        api.to(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY)(packed, result.data);
        if (!values.empty()) std::memcpy(api.writable_bytes(packed, 0), values.data(), values.size());
        api.destroy(result.data); api.from(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY)(result.data, packed);
        api.destructor(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY)(packed);
        return result;
    }
    static Value array(const std::vector<Value>& values) {
        Value result; api.destroy(result.data); GDExtensionCallError error{};
        api.construct(GDEXTENSION_VARIANT_TYPE_ARRAY, result.data, nullptr, 0, &error);
        for (const auto& value : values) result.invoke("append", {value});
        return result;
    }
    static Value dictionary(std::initializer_list<std::pair<const char*, Value>> entries) {
        Value result; api.destroy(result.data); GDExtensionCallError error{};
        api.construct(GDEXTENSION_VARIANT_TYPE_DICTIONARY, result.data, nullptr, 0, &error);
        for (const auto& entry : entries) result.invoke("set", {text(entry.first), entry.second});
        return result;
    }
    template<class T, class Index> static Value packed(GDExtensionVariantType type, std::size_t size, const std::vector<T>& values, Index index) {
        Value result; api.destroy(result.data); GDExtensionCallError error{};
        api.construct(type, result.data, nullptr, 0, &error);
        result.invoke("resize", {integer(values.size())});
        alignas(16) std::byte packed[64];
        if (size > sizeof(packed)) throw std::runtime_error("Packed array ABI is unsupported");
        api.to(type)(packed, result.data);
        if (!values.empty()) std::memcpy(index(packed, 0), values.data(), values.size() * sizeof(T));
        api.destroy(result.data); api.from(type)(result.data, packed); api.destructor(type)(packed);
        return result;
    }
};

#include "../../plugins/honkai_mmd/runtime/native_bridge.inl"

struct NativeCapture {
    mocap::Tracker tracker;
    std::mutex mutex;
    std::mutex inference_mutex;
    std::shared_ptr<mocap::WindowsCamera> camera;
    std::thread worker;
    std::atomic<bool> running{false};
    std::atomic<double> fps{0};
    bool initialized = false;
    bool pending = false;
    mocap::Frame latest;
    bool preview_enabled = false;
    bool preview_pending = false;
    mocap::Frame preview_frame;
    mocap::CameraFrame preview_image;
    std::int64_t polled_timestamp = 0;
    std::int64_t polled_sequence = -1;
    std::int64_t sequence = 0;
    std::string error;
    ~NativeCapture() { stop(); }
    void fail(const std::string& message) { std::lock_guard<std::mutex> lock(mutex); error = message; }
    bool initialize(Value models) {
        stop();
        if (api.type(models.data) != GDEXTENSION_VARIANT_TYPE_ARRAY || models.invoke("size").integer() != 3) throw std::invalid_argument("Expected pose, hand and face model buffers");
        std::array<std::vector<std::uint8_t>, 3> buffers;
        for (int index = 0; index < 3; ++index) buffers[index] = models.at(index).bytes();
        wchar_t path[32768];
        DWORD size = GetModuleFileNameW(native_module, path, static_cast<DWORD>(std::size(path)));
        if (!size || size >= std::size(path)) { fail("Cannot locate the native runtime directory"); return false; }
        std::wstring library(path, size);
        library = library.substr(0, library.find_last_of(L"\\/")) + L"/libmediapipe.dll";
        std::lock_guard<std::mutex> inference_lock(inference_mutex);
        initialized = tracker.initialize(library, buffers);
        fail(initialized ? "" : tracker.error());
        return initialized;
    }
    void stop() {
        running.store(false);
        std::shared_ptr<mocap::WindowsCamera> owned_camera;
        { std::lock_guard<std::mutex> lock(mutex); owned_camera = camera; }
        if (owned_camera) owned_camera->cancel();
        if (worker.joinable()) worker.join();
        { std::lock_guard<std::mutex> lock(mutex); camera.reset(); pending = false; preview_pending = false; preview_image = {}; preview_frame = {}; }
        fps.store(0);
    }
    bool start(int device, int width, int height, int rate) {
        stop();
        if (!initialized || device < 0 || device > 255 || width < 160 || width > 3840 || height < 120 || height > 2160 || rate < 1 || rate > 60) {
            fail("Initialize MediaPipe and select valid camera settings first"); return false;
        }
        auto owned_camera = std::make_shared<mocap::WindowsCamera>();
        { std::lock_guard<std::mutex> lock(mutex); error.clear(); camera = owned_camera; }
        running.store(true);
        worker = std::thread([this, owned_camera, device, width, height, rate] {
            HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
            if (FAILED(com)) { fail("Cannot initialize camera COM thread"); running.store(false); return; }
            if (!owned_camera->open(device, width, height, rate)) {
                fail(owned_camera->error()); owned_camera->close(); running.store(false); CoUninitialize(); return;
            }
            const auto started = std::chrono::steady_clock::now();
            std::int64_t frames = 0;
            while (running.load()) {
                mocap::CameraFrame image;
                if (!owned_camera->next(image, running)) {
                    const auto camera_error = owned_camera->error();
                    if (!camera_error.empty()) { fail(camera_error); break; }
                    continue;
                }
                const auto tick = std::chrono::steady_clock::now();
                mocap::Frame frame;
                bool detected;
                { std::lock_guard<std::mutex> lock(inference_mutex); detected = tracker.detect(image.rgb.data(), image.width, image.height, static_cast<std::int64_t>(GetTickCount64()), frame); }
                if (!detected) { fail(tracker.error()); break; }
                frame.sequence = sequence++;
                {
                    std::lock_guard<std::mutex> lock(mutex);
                    latest = frame; pending = true;
                    if (preview_enabled) { preview_frame = frame; preview_image = std::move(image); preview_pending = true; }
                }
                ++frames;
                const double elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count();
                fps.store(frames / std::max(0.001, elapsed));
                std::this_thread::sleep_until(tick + std::chrono::microseconds(1000000 / rate));
            }
            owned_camera->cancel();
            // Release Media Foundation on the thread which initialized COM.
            { std::lock_guard<std::mutex> lock(mutex); camera.reset(); }
            owned_camera->close();
            running.store(false);
            CoUninitialize();
        });
        return true;
    }
    Value poll() {
        std::lock_guard<std::mutex> lock(mutex);
        if (!pending) return Value();
        pending = false; polled_timestamp = latest.timestamp_ms; polled_sequence = latest.sequence;
        return Value::frame(latest);
    }
    void set_preview(bool enabled) {
        std::lock_guard<std::mutex> lock(mutex);
        preview_enabled = enabled;
        preview_pending = false; preview_image = {}; preview_frame = {};
    }
    Value poll_preview() {
        std::lock_guard<std::mutex> lock(mutex);
        if (!preview_enabled || !preview_pending) return Value();
        preview_pending = false;
        return Value::array({Value::integer(preview_image.width), Value::integer(preview_image.height),
            Value::bytes(preview_image.rgb), Value::frame(preview_frame),
            Value::floats(preview_frame.face_image.data(), preview_frame.face_image.size()),
            Value::integer(preview_frame.sequence), Value::integer(preview_frame.timestamp_ms)});
    }
    Value detect(Value pixels, int width, int height, std::int64_t timestamp) {
        if (running.load()) throw std::invalid_argument("Stop camera capture before processing a test image");
        auto data = pixels.bytes();
        if (width < 1 || height < 1 || width > 8192 || height > 8192 || data.size() != static_cast<std::size_t>(width) * height * 3) throw std::invalid_argument("RGB byte count does not match image size");
        mocap::Frame frame;
        std::lock_guard<std::mutex> lock(inference_mutex);
        if (!tracker.detect(data.data(), width, height, timestamp, frame)) { fail(tracker.error()); return Value(); }
        polled_timestamp = frame.timestamp_ms; polled_sequence = sequence++; frame.sequence = polled_sequence;
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (preview_enabled) { preview_frame = frame; preview_image = {width, height, std::move(data)}; preview_pending = true; }
        }
        return Value::frame(frame);
    }
};

struct NativeArchive {
    std::thread worker;
    std::atomic_bool running{false};
    std::atomic_bool cancelled{false};
    std::mutex mutex;
    std::string error;
    std::string result_path;
    ~NativeArchive() { cancel(); }
    void cancel() {
        cancelled.store(true);
        if (worker.joinable()) worker.join();
        running.store(false);
    }
    bool start(const std::string& archive, const std::string& cache) {
        if (running.load()) return false;
        cancel();
        { std::lock_guard<std::mutex> lock(mutex); error.clear(); result_path.clear(); }
        cancelled.store(false);
        running.store(true);
        try {
            worker = std::thread([this, archive, cache] {
                HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
                try {
                    if (FAILED(com)) throw std::runtime_error("Cannot initialize archive worker COM thread");
                    wchar_t path[32768];
                    DWORD size = GetModuleFileNameW(native_module, path, static_cast<DWORD>(std::size(path)));
                    if (!size || size >= std::size(path)) throw std::runtime_error("Cannot locate native archive runtime");
                    mocap::ArchiveService service(std::filesystem::path(std::wstring(path, size)).parent_path() / L"7z.dll");
                    const auto extracted = service.extract(std::filesystem::u8path(archive), std::filesystem::u8path(cache), {}, &cancelled);
                    std::lock_guard<std::mutex> lock(mutex);
                    if (!cancelled.load()) result_path = extracted.index_json.u8string();
                } catch (const std::exception& exception) {
                    std::lock_guard<std::mutex> lock(mutex); error = exception.what();
                }
                if (SUCCEEDED(com)) CoUninitialize();
                running.store(false);
            });
        } catch (...) { running.store(false); throw; }
        return true;
    }
};

struct NativeVideo {
    mocap::SpoutOutput output;
    std::mutex mutex;
    std::string error;
};

enum class Method { Initialize, Start, Stop, Poll, Running, Error, Fps, Timestamp, Sequence, Detect, SetPreview, PollPreview,
                    ArchiveStart, ArchiveRunning, ArchiveResult, ArchiveError, ArchiveCancel,
                    VideoCreate, VideoSend, VideoClose, VideoError, VideoName, PmxRead, PmxError };
struct MethodInfo {
    const char* name;
    Method method;
    GDExtensionVariantType result;
    std::vector<GDExtensionVariantType> arguments;
};

void invoke_method(void* userdata, GDExtensionClassInstancePtr instance, const GDExtensionConstVariantPtr* arguments,
                   GDExtensionInt count, GDExtensionVariantPtr returned, GDExtensionCallError* call_error) {
    auto& method = *static_cast<MethodInfo*>(userdata);
    *call_error = {};
    Value result;
    if (count != static_cast<GDExtensionInt>(method.arguments.size())) {
        call_error->error = count < static_cast<GDExtensionInt>(method.arguments.size()) ? GDEXTENSION_CALL_ERROR_TOO_FEW_ARGUMENTS : GDEXTENSION_CALL_ERROR_TOO_MANY_ARGUMENTS;
        call_error->expected = static_cast<int32_t>(method.arguments.size()); api.copy(returned, result.data); return;
    }
    for (int index = 0; index < count; ++index) {
        if (api.type(arguments[index]) != method.arguments[index]) {
            call_error->error = GDEXTENSION_CALL_ERROR_INVALID_ARGUMENT; call_error->argument = index;
            call_error->expected = method.arguments[index]; api.copy(returned, result.data); return;
        }
    }
    if (method.method >= Method::PmxRead) {
        auto& reader = *static_cast<NativePmx*>(instance);
        try {
            if (method.method == Method::PmxRead) result = reader.read(Value(arguments[0]).text());
            else result = Value::text(reader.error);
        } catch (const std::exception& exception) { reader.error = exception.what(); }
        api.copy(returned, result.data);
        return;
    }
    if (method.method >= Method::VideoCreate) {
        auto& video = *static_cast<NativeVideo*>(instance);
        std::lock_guard<std::mutex> lock(video.mutex);
        try {
            switch (method.method) {
                case Method::VideoCreate:
                    video.error.clear();
                    result = Value::integer(static_cast<std::int64_t>(video.output.create(
                        Value(arguments[0]).integer(), Value(arguments[1]).integer(),
                        static_cast<int>(Value(arguments[2]).integer()), static_cast<int>(Value(arguments[3]).integer()))));
                    break;
                case Method::VideoSend: result = Value::boolean(video.output.send()); break;
                case Method::VideoClose: video.output.close(); break;
                case Method::VideoError: result = Value::text(video.error); break;
                case Method::VideoName: result = Value::text(video.output.sender_name()); break;
                default: break;
            }
        } catch (const std::exception& exception) { video.error = exception.what(); }
        api.copy(returned, result.data);
        return;
    }
    if (method.method >= Method::ArchiveStart) {
        auto& archive = *static_cast<NativeArchive*>(instance);
        try {
            switch (method.method) {
                case Method::ArchiveStart: result = Value::boolean(archive.start(Value(arguments[0]).text(), Value(arguments[1]).text())); break;
                case Method::ArchiveRunning: result = Value::boolean(archive.running.load()); break;
                case Method::ArchiveResult: { std::lock_guard<std::mutex> lock(archive.mutex); result = Value::text(archive.result_path); break; }
                case Method::ArchiveError: { std::lock_guard<std::mutex> lock(archive.mutex); result = Value::text(archive.error); break; }
                case Method::ArchiveCancel: archive.cancel(); break;
                default: break;
            }
        } catch (const std::exception& exception) {
            std::lock_guard<std::mutex> lock(archive.mutex); archive.error = exception.what();
        }
        api.copy(returned, result.data);
        return;
    }
    auto& capture = *static_cast<NativeCapture*>(instance);
    try {
        auto integer = [&](int index) { return Value(arguments[index]).integer(); };
        switch (method.method) {
            case Method::Initialize: result = Value::boolean(capture.initialize(Value(arguments[0]))); break;
            case Method::Start: result = Value::boolean(capture.start(static_cast<int>(integer(0)), static_cast<int>(integer(1)), static_cast<int>(integer(2)), static_cast<int>(integer(3)))); break;
            case Method::Stop: capture.stop(); break;
            case Method::Poll: result = capture.poll(); break;
            case Method::Running: result = Value::boolean(capture.running.load()); break;
            case Method::Error: { std::lock_guard<std::mutex> lock(capture.mutex); result = Value::text(capture.error); break; }
            case Method::Fps: result = Value::number(capture.fps.load()); break;
            case Method::Timestamp: result = Value::integer(capture.polled_timestamp); break;
            case Method::Sequence: result = Value::integer(capture.polled_sequence); break;
            case Method::Detect: result = capture.detect(Value(arguments[0]), static_cast<int>(integer(1)), static_cast<int>(integer(2)), integer(3)); break;
            case Method::SetPreview: { GDExtensionBool enabled = false; api.to(GDEXTENSION_VARIANT_TYPE_BOOL)(&enabled, const_cast<void*>(arguments[0])); capture.set_preview(enabled); break; }
            case Method::PollPreview: result = capture.poll_preview(); break;
        }
    } catch (const std::exception& exception) {
        capture.fail(exception.what());
    }
    api.copy(returned, result.data);
}

GDExtensionObjectPtr create_capture(void*, GDExtensionBool notify) {
    try {
        auto capture = std::make_unique<NativeCapture>();
        Name parent("RefCounted"), name("NativeMocap");
        auto object = api.object(parent.data);
        if (!object) return nullptr;
        api.instance(object, name.data, capture.release());
        if (notify) { auto value = Value::object(object); value.invoke("notification", {Value::integer(0), Value::boolean(false)}); }
        return object;
    } catch (...) { return nullptr; }
}
void free_capture(void*, GDExtensionClassInstancePtr instance) { delete static_cast<NativeCapture*>(instance); }

GDExtensionObjectPtr create_archive(void*, GDExtensionBool notify) {
    try {
        auto archive = std::make_unique<NativeArchive>();
        Name parent("RefCounted"), name("NativeModelArchive");
        auto object = api.object(parent.data);
        if (!object) return nullptr;
        api.instance(object, name.data, archive.release());
        if (notify) { auto value = Value::object(object); value.invoke("notification", {Value::integer(0), Value::boolean(false)}); }
        return object;
    } catch (...) { return nullptr; }
}
void free_archive(void*, GDExtensionClassInstancePtr instance) { delete static_cast<NativeArchive*>(instance); }

GDExtensionObjectPtr create_video(void*, GDExtensionBool notify) {
    try {
        auto video = std::make_unique<NativeVideo>();
        Name parent("RefCounted"), name("NativeSpoutOutput");
        auto object = api.object(parent.data);
        if (!object) return nullptr;
        api.instance(object, name.data, video.release());
        if (notify) { auto value = Value::object(object); value.invoke("notification", {Value::integer(0), Value::boolean(false)}); }
        return object;
    } catch (...) { return nullptr; }
}
void free_video(void*, GDExtensionClassInstancePtr instance) { delete static_cast<NativeVideo*>(instance); }

GDExtensionObjectPtr create_pmx(void*, GDExtensionBool notify) {
    try {
        auto reader = std::make_unique<NativePmx>();
        Name parent("RefCounted"), name("NativePmxReader");
        auto object = api.object(parent.data);
        if (!object) return nullptr;
        api.instance(object, name.data, reader.release());
        if (notify) { auto value = Value::object(object); value.invoke("notification", {Value::integer(0), Value::boolean(false)}); }
        return object;
    } catch (...) { return nullptr; }
}
void free_pmx(void*, GDExtensionClassInstancePtr instance) { delete static_cast<NativePmx*>(instance); }

void initialize(void*, GDExtensionInitializationLevel level) {
    if (level != GDEXTENSION_INITIALIZATION_SCENE) return;
    Name name("NativeMocap"), parent("RefCounted"), empty("");
    GDExtensionClassCreationInfo6 info{};
    info.is_exposed = true; info.create_instance_func = create_capture; info.free_instance_func = free_capture;
    api.register_class(class_library, name.data, parent.data, &info);
    Name archive_name("NativeModelArchive");
    GDExtensionClassCreationInfo6 archive_info{};
    archive_info.is_exposed = true; archive_info.create_instance_func = create_archive; archive_info.free_instance_func = free_archive;
    api.register_class(class_library, archive_name.data, parent.data, &archive_info);
    Name video_name("NativeSpoutOutput");
    GDExtensionClassCreationInfo6 video_info{};
    video_info.is_exposed = true; video_info.create_instance_func = create_video; video_info.free_instance_func = free_video;
    api.register_class(class_library, video_name.data, parent.data, &video_info);
    Name pmx_name("NativePmxReader");
    GDExtensionClassCreationInfo6 pmx_info{};
    pmx_info.is_exposed = true; pmx_info.create_instance_func = create_pmx; pmx_info.free_instance_func = free_pmx;
    api.register_class(class_library, pmx_name.data, parent.data, &pmx_info);
    static std::array<MethodInfo, 24> methods{{
        {"initialize", Method::Initialize, GDEXTENSION_VARIANT_TYPE_BOOL, {GDEXTENSION_VARIANT_TYPE_ARRAY}},
        {"start_camera", Method::Start, GDEXTENSION_VARIANT_TYPE_BOOL, {GDEXTENSION_VARIANT_TYPE_INT,GDEXTENSION_VARIANT_TYPE_INT,GDEXTENSION_VARIANT_TYPE_INT,GDEXTENSION_VARIANT_TYPE_INT}},
        {"stop", Method::Stop, GDEXTENSION_VARIANT_TYPE_NIL, {}},
        {"poll", Method::Poll, GDEXTENSION_VARIANT_TYPE_PACKED_FLOAT32_ARRAY, {}},
        {"is_running", Method::Running, GDEXTENSION_VARIANT_TYPE_BOOL, {}},
        {"get_error", Method::Error, GDEXTENSION_VARIANT_TYPE_STRING, {}},
        {"get_fps", Method::Fps, GDEXTENSION_VARIANT_TYPE_FLOAT, {}},
        {"get_timestamp_ms", Method::Timestamp, GDEXTENSION_VARIANT_TYPE_INT, {}},
        {"get_sequence", Method::Sequence, GDEXTENSION_VARIANT_TYPE_INT, {}},
        {"detect_rgb", Method::Detect, GDEXTENSION_VARIANT_TYPE_PACKED_FLOAT32_ARRAY, {GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY,GDEXTENSION_VARIANT_TYPE_INT,GDEXTENSION_VARIANT_TYPE_INT,GDEXTENSION_VARIANT_TYPE_INT}},
        {"set_preview_enabled", Method::SetPreview, GDEXTENSION_VARIANT_TYPE_NIL, {GDEXTENSION_VARIANT_TYPE_BOOL}},
        {"poll_preview", Method::PollPreview, GDEXTENSION_VARIANT_TYPE_ARRAY, {}},
        {"start_extract", Method::ArchiveStart, GDEXTENSION_VARIANT_TYPE_BOOL, {GDEXTENSION_VARIANT_TYPE_STRING,GDEXTENSION_VARIANT_TYPE_STRING}},
        {"is_running", Method::ArchiveRunning, GDEXTENSION_VARIANT_TYPE_BOOL, {}},
        {"get_result_path", Method::ArchiveResult, GDEXTENSION_VARIANT_TYPE_STRING, {}},
        {"get_error", Method::ArchiveError, GDEXTENSION_VARIANT_TYPE_STRING, {}},
        {"cancel", Method::ArchiveCancel, GDEXTENSION_VARIANT_TYPE_NIL, {}},
        {"create", Method::VideoCreate, GDEXTENSION_VARIANT_TYPE_INT, {GDEXTENSION_VARIANT_TYPE_INT,GDEXTENSION_VARIANT_TYPE_INT,GDEXTENSION_VARIANT_TYPE_INT,GDEXTENSION_VARIANT_TYPE_INT}},
        {"send", Method::VideoSend, GDEXTENSION_VARIANT_TYPE_BOOL, {}},
        {"close", Method::VideoClose, GDEXTENSION_VARIANT_TYPE_NIL, {}},
        {"get_error", Method::VideoError, GDEXTENSION_VARIANT_TYPE_STRING, {}},
        {"get_sender_name", Method::VideoName, GDEXTENSION_VARIANT_TYPE_STRING, {}},
        {"read_file", Method::PmxRead, GDEXTENSION_VARIANT_TYPE_DICTIONARY, {GDEXTENSION_VARIANT_TYPE_STRING}},
        {"get_error", Method::PmxError, GDEXTENSION_VARIANT_TYPE_STRING, {}}
    }};
    alignas(16) std::byte empty_string[gdabi::string_size]; api.string(empty_string, "");
    for (auto& method : methods) {
        Name method_name(method.name);
        GDExtensionPropertyInfo result{};
        result.type = method.result; result.name = empty.data; result.class_name = empty.data; result.hint_string = empty_string;
        std::vector<GDExtensionPropertyInfo> arguments(method.arguments.size());
        std::vector<GDExtensionClassMethodArgumentMetadata> metadata(method.arguments.size(), GDEXTENSION_METHOD_ARGUMENT_METADATA_NONE);
        for (std::size_t index = 0; index < arguments.size(); ++index) {
            arguments[index] = result; arguments[index].type = method.arguments[index];
        }
        GDExtensionClassMethodInfo method_info{};
        method_info.name = method_name.data; method_info.method_userdata = &method; method_info.call_func = invoke_method;
        method_info.method_flags = GDEXTENSION_METHOD_FLAG_NORMAL;
        method_info.has_return_value = method.result != GDEXTENSION_VARIANT_TYPE_NIL;
        method_info.return_value_info = &result;
        method_info.argument_count = static_cast<uint32_t>(arguments.size());
        method_info.arguments_info = arguments.data(); method_info.arguments_metadata = metadata.data();
        auto owner = method.method >= Method::PmxRead ? pmx_name.data : (method.method >= Method::VideoCreate ? video_name.data : (method.method >= Method::ArchiveStart ? archive_name.data : name.data));
        api.register_method(class_library, owner, &method_info);
    }
    api.destructor(GDEXTENSION_VARIANT_TYPE_STRING)(empty_string);
}

void deinitialize(void*, GDExtensionInitializationLevel level) {
    if (level == GDEXTENSION_INITIALIZATION_SCENE) {
        Name pmx("NativePmxReader"); api.unregister_class(class_library, pmx.data);
        Name video("NativeSpoutOutput"); api.unregister_class(class_library, video.data);
        Name archive("NativeModelArchive"); api.unregister_class(class_library, archive.data);
        Name name("NativeMocap"); api.unregister_class(class_library, name.data);
    }
}
}

BOOL WINAPI DllMain(HINSTANCE module, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) native_module = module;
    return TRUE;
}

extern "C" __declspec(dllexport) GDExtensionBool mocap_library_init(GDExtensionInterfaceGetProcAddress get,
    GDExtensionClassLibraryPtr library, GDExtensionInitialization* initialization) {
    class_library = library;
#define LOAD(field, type, name) api.field = reinterpret_cast<type>(get(name)); if (!api.field) return false
    LOAD(nil, GDExtensionInterfaceVariantNewNil, "variant_new_nil"); LOAD(copy, GDExtensionInterfaceVariantNewCopy, "variant_new_copy");
    LOAD(destroy, GDExtensionInterfaceVariantDestroy, "variant_destroy"); LOAD(type, GDExtensionInterfaceVariantGetType, "variant_get_type");
    LOAD(construct, GDExtensionInterfaceVariantConstruct, "variant_construct"); LOAD(call, GDExtensionInterfaceVariantCall, "variant_call");
    LOAD(indexed, GDExtensionInterfaceVariantGetIndexed, "variant_get_indexed");
    LOAD(from, GDExtensionInterfaceGetVariantFromTypeConstructor, "get_variant_from_type_constructor");
    LOAD(to, GDExtensionInterfaceGetVariantToTypeConstructor, "get_variant_to_type_constructor");
    LOAD(destructor, GDExtensionInterfaceVariantGetPtrDestructor, "variant_get_ptr_destructor");
    LOAD(name, GDExtensionInterfaceStringNameNewWithUtf8Chars, "string_name_new_with_utf8_chars");
    LOAD(string, GDExtensionInterfaceStringNewWithUtf8Chars, "string_new_with_utf8_chars");
    LOAD(utf8, GDExtensionInterfaceStringToUtf8Chars, "string_to_utf8_chars");
    LOAD(bytes, GDExtensionInterfacePackedByteArrayOperatorIndexConst, "packed_byte_array_operator_index_const");
    LOAD(writable_bytes, GDExtensionInterfacePackedByteArrayOperatorIndex, "packed_byte_array_operator_index");
    LOAD(floats, GDExtensionInterfacePackedFloat32ArrayOperatorIndex, "packed_float32_array_operator_index");
    LOAD(vectors, GDExtensionInterfacePackedVector3ArrayOperatorIndex, "packed_vector3_array_operator_index");
    LOAD(uvs, GDExtensionInterfacePackedVector2ArrayOperatorIndex, "packed_vector2_array_operator_index");
    LOAD(colors, GDExtensionInterfacePackedColorArrayOperatorIndex, "packed_color_array_operator_index");
    LOAD(ints, GDExtensionInterfacePackedInt32ArrayOperatorIndex, "packed_int32_array_operator_index");
    LOAD(register_class, GDExtensionInterfaceClassdbRegisterExtensionClass6, "classdb_register_extension_class6");
    LOAD(unregister_class, GDExtensionInterfaceClassdbUnregisterExtensionClass, "classdb_unregister_extension_class");
    LOAD(register_method, GDExtensionInterfaceClassdbRegisterExtensionClassMethod, "classdb_register_extension_class_method");
    LOAD(object, GDExtensionInterfaceClassdbConstructObject3, "classdb_construct_object3");
    LOAD(instance, GDExtensionInterfaceObjectSetInstance, "object_set_instance");
#undef LOAD
    initialization->minimum_initialization_level = GDEXTENSION_INITIALIZATION_SCENE;
    initialization->initialize = initialize; initialization->deinitialize = deinitialize; initialization->userdata = nullptr;
    return true;
}
