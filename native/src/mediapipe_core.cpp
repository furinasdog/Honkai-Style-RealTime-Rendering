#include "mediapipe_core.hpp"
#include <windows.h>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <map>
#include <mutex>
#include <stdexcept>
#define MP_EXPORT
#include "mediapipe/tasks/c/core/common.h"
#include "mediapipe/tasks/c/vision/pose_landmarker/pose_landmarker.h"
#include "mediapipe/tasks/c/vision/hand_landmarker/hand_landmarker.h"
#include "mediapipe/tasks/c/vision/face_landmarker/face_landmarker.h"

namespace mocap {
static HMODULE process_library(const std::wstring& path) {
    static std::mutex mutex;
    static std::map<std::wstring, HMODULE> libraries;
    std::lock_guard<std::mutex> lock(mutex);
    auto& library = libraries[path];
    if (!library) library = LoadLibraryExW(path.c_str(), nullptr, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
    return library;
}

static constexpr const char* face_names[] = {
    "_neutral", "browDownLeft", "browDownRight", "browInnerUp", "browOuterUpLeft", "browOuterUpRight",
    "cheekPuff", "cheekSquintLeft", "cheekSquintRight", "eyeBlinkLeft", "eyeBlinkRight", "eyeLookDownLeft",
    "eyeLookDownRight", "eyeLookInLeft", "eyeLookInRight", "eyeLookOutLeft", "eyeLookOutRight", "eyeLookUpLeft",
    "eyeLookUpRight", "eyeSquintLeft", "eyeSquintRight", "eyeWideLeft", "eyeWideRight", "jawForward", "jawLeft",
    "jawOpen", "jawRight", "mouthClose", "mouthDimpleLeft", "mouthDimpleRight", "mouthFrownLeft", "mouthFrownRight",
    "mouthFunnel", "mouthLeft", "mouthLowerDownLeft", "mouthLowerDownRight", "mouthPressLeft", "mouthPressRight",
    "mouthPucker", "mouthRight", "mouthRollLower", "mouthRollUpper", "mouthShrugLower", "mouthShrugUpper",
    "mouthSmileLeft", "mouthSmileRight", "mouthStretchLeft", "mouthStretchRight", "mouthUpperUpLeft",
    "mouthUpperUpRight", "noseSneerLeft", "noseSneerRight"
};

struct Tracker::Impl {
    HMODULE library = nullptr;
    std::string error;
    std::array<std::vector<std::uint8_t>, 3> models;
    MpPoseLandmarkerPtr pose = nullptr;
    MpHandLandmarkerPtr hands = nullptr;
    MpFaceLandmarkerPtr face = nullptr;
    std::int64_t timestamp = -1;
#define DECLARE_FUNCTION(name) decltype(&::name) name = nullptr
    DECLARE_FUNCTION(MpErrorFree);
    DECLARE_FUNCTION(MpImageCreateFromUint8Data);
    DECLARE_FUNCTION(MpImageFree);
    DECLARE_FUNCTION(MpPoseLandmarkerCreate);
    DECLARE_FUNCTION(MpPoseLandmarkerDetectForVideo);
    DECLARE_FUNCTION(MpPoseLandmarkerCloseResult);
    DECLARE_FUNCTION(MpPoseLandmarkerClose);
    DECLARE_FUNCTION(MpHandLandmarkerCreate);
    DECLARE_FUNCTION(MpHandLandmarkerDetectForVideo);
    DECLARE_FUNCTION(MpHandLandmarkerCloseResult);
    DECLARE_FUNCTION(MpHandLandmarkerClose);
    DECLARE_FUNCTION(MpFaceLandmarkerCreate);
    DECLARE_FUNCTION(MpFaceLandmarkerDetectForVideo);
    DECLARE_FUNCTION(MpFaceLandmarkerCloseResult);
    DECLARE_FUNCTION(MpFaceLandmarkerClose);
#undef DECLARE_FUNCTION
    template<class T> void load(T& function, const char* name) {
        function = reinterpret_cast<T>(GetProcAddress(library, name));
        if (!function) throw std::runtime_error(std::string("MediaPipe is missing ") + name);
    }
    bool status(MpStatus code, char* message) {
        if (code != 0) error = message ? message : "MediaPipe returned an error";
        if (message) MpErrorFree(message);
        return code == 0;
    }
    MpBaseOptions options(std::size_t index) {
        MpBaseOptions value{};
        value.model_asset_buffer = reinterpret_cast<const char*>(models[index].data());
        value.model_asset_buffer_count = static_cast<unsigned int>(models[index].size());
        value.file_descriptor = -1;
        value.delegate = MP_DELEGATE_CPU;
        value.host_environment = MP_HOST_ENVIRONMENT_UNKNOWN;
        value.host_system = MP_HOST_SYSTEM_WINDOWS;
        return value;
    }
};

Tracker::Tracker() : impl(std::make_unique<Impl>()) {}
Tracker::~Tracker() { close(); }
const std::string& Tracker::error() const { return impl->error; }

bool Tracker::initialize(const std::wstring& path, const std::array<std::vector<std::uint8_t>, 3>& data) {
    close();
    impl->error.clear();
    for (const auto& model : data) {
        if (model.empty() || model.size() > 128 * 1024 * 1024) {
            impl->error = "MediaPipe model data is missing or too large";
            return false;
        }
    }
    impl->library = process_library(path);
    if (!impl->library) {
        impl->error = "Cannot load the bundled native MediaPipe library";
        return false;
    }
    try {
#define LOAD_FUNCTION(name) impl->load(impl->name, #name)
        LOAD_FUNCTION(MpErrorFree); LOAD_FUNCTION(MpImageCreateFromUint8Data); LOAD_FUNCTION(MpImageFree);
        LOAD_FUNCTION(MpPoseLandmarkerCreate); LOAD_FUNCTION(MpPoseLandmarkerDetectForVideo);
        LOAD_FUNCTION(MpPoseLandmarkerCloseResult); LOAD_FUNCTION(MpPoseLandmarkerClose);
        LOAD_FUNCTION(MpHandLandmarkerCreate); LOAD_FUNCTION(MpHandLandmarkerDetectForVideo);
        LOAD_FUNCTION(MpHandLandmarkerCloseResult); LOAD_FUNCTION(MpHandLandmarkerClose);
        LOAD_FUNCTION(MpFaceLandmarkerCreate); LOAD_FUNCTION(MpFaceLandmarkerDetectForVideo);
        LOAD_FUNCTION(MpFaceLandmarkerCloseResult); LOAD_FUNCTION(MpFaceLandmarkerClose);
#undef LOAD_FUNCTION
        impl->models = data;
        char* error = nullptr;
        MpPoseLandmarkerOptions pose{};
        pose.base_options = impl->options(0); pose.running_mode = MP_RUNNING_MODE_VIDEO;
        auto status = impl->MpPoseLandmarkerCreate(&pose, &impl->pose, &error);
        if (!impl->status(status, error)) { close(); return false; }
        MpHandLandmarkerOptions hands{};
        hands.base_options = impl->options(1); hands.running_mode = MP_RUNNING_MODE_VIDEO; hands.num_hands = 2;
        error = nullptr;
        status = impl->MpHandLandmarkerCreate(&hands, &impl->hands, &error);
        if (!impl->status(status, error)) { close(); return false; }
        MpFaceLandmarkerOptions face{};
        face.base_options = impl->options(2); face.running_mode = MP_RUNNING_MODE_VIDEO;
        face.output_face_blendshapes = true; face.output_facial_transformation_matrixes = true;
        error = nullptr;
        status = impl->MpFaceLandmarkerCreate(&face, &impl->face, &error);
        if (!impl->status(status, error)) { close(); return false; }
        impl->timestamp = -1;
        return true;
    } catch (const std::exception& exception) {
        impl->error = exception.what();
        close();
        return false;
    }
}

void Tracker::close() {
    if (!impl->library) return;
    char* message = nullptr;
    if (impl->pose && impl->MpPoseLandmarkerClose) { impl->MpPoseLandmarkerClose(impl->pose, &message); if (message) impl->MpErrorFree(message); }
    impl->pose = nullptr; message = nullptr;
    if (impl->hands && impl->MpHandLandmarkerClose) { impl->MpHandLandmarkerClose(impl->hands, &message); if (message) impl->MpErrorFree(message); }
    impl->hands = nullptr; message = nullptr;
    if (impl->face && impl->MpFaceLandmarkerClose) { impl->MpFaceLandmarkerClose(impl->face, &message); if (message) impl->MpErrorFree(message); }
    impl->face = nullptr;
    // MediaPipe owns process-wide worker pools; keep its code mapped until process teardown.
    impl->library = nullptr;
    for (auto& model : impl->models) model.clear();
}

template<class T> static void landmarks(float* destination, const T& points, int count, bool visibility) {
    for (int index = 0; index < count; ++index) {
        const auto& point = points.landmarks[index];
        *destination++ = point.x; *destination++ = point.y; *destination++ = point.z;
        if (visibility) *destination++ = point.has_visibility ? point.visibility : 0.0f;
    }
}

bool Tracker::detect(const std::uint8_t* rgb, int width, int height, std::int64_t timestamp, Frame& output) {
    if (!impl->pose || !rgb || width < 1 || height < 1 || width > 8192 || height > 8192 || timestamp <= impl->timestamp) {
        impl->error = "Invalid frame dimensions, tracker state or non-increasing timestamp";
        return false;
    }
    MpImagePtr image = nullptr;
    char* error = nullptr;
    auto status = impl->MpImageCreateFromUint8Data(kMpImageFormatSrgb, width, height, rgb, width * height * 3, &image, &error);
    if (!impl->status(status, error)) return false;
    MpPoseLandmarkerResult pose{}; MpHandLandmarkerResult hands{}; MpFaceLandmarkerResult face{};
    error = nullptr;
    status = impl->MpPoseLandmarkerDetectForVideo(impl->pose, image, nullptr, timestamp, &pose, &error);
    bool ok = impl->status(status, error);
    if (ok) { error = nullptr; status = impl->MpHandLandmarkerDetectForVideo(impl->hands, image, nullptr, timestamp, &hands, &error); ok = impl->status(status, error); }
    if (ok) { error = nullptr; status = impl->MpFaceLandmarkerDetectForVideo(impl->face, image, nullptr, timestamp, &face, &error); ok = impl->status(status, error); }
    output.values.fill(0);
    output.face_image.clear();
    if (ok && pose.pose_landmarks_count && pose.pose_world_landmarks_count && pose.pose_landmarks[0].landmarks_count == 33 && pose.pose_world_landmarks[0].landmarks_count == 33) {
        output.values[0] = 1;
        landmarks(output.values.data() + 4, pose.pose_world_landmarks[0], 33, true);
        landmarks(output.values.data() + 136, pose.pose_landmarks[0], 33, true);
    }
    auto count = std::min({hands.hand_landmarks_count, hands.hand_world_landmarks_count, hands.handedness_count, 2u});
    for (unsigned int hand = 0; ok && hand < count; ++hand) {
        if (hands.hand_landmarks[hand].landmarks_count != 21 || hands.hand_world_landmarks[hand].landmarks_count != 21 || !hands.handedness[hand].categories_count) continue;
        float* destination = output.values.data() + 268 + static_cast<int>(output.values[1]) * 127;
        const auto* name = hands.handedness[hand].categories[0].category_name;
        destination[0] = name && std::strcmp(name, "Left") == 0 ? 0.0f : 1.0f;
        landmarks(destination + 1, hands.hand_world_landmarks[hand], 21, false);
        landmarks(destination + 64, hands.hand_landmarks[hand], 21, false);
        output.values[1] += 1;
    }
    if (ok && face.face_landmarks_count) {
        output.values[2] = 1;
        const auto& points = face.face_landmarks[0];
        if (points.landmarks_count <= 1024) {
            output.face_image.reserve(points.landmarks_count * 3);
            for (unsigned int index = 0; index < points.landmarks_count; ++index) {
                const auto& point = points.landmarks[index];
                if (std::isfinite(point.x) && std::isfinite(point.y) && std::isfinite(point.z)) {
                    output.face_image.insert(output.face_image.end(), {point.x, point.y, point.z});
                } else { output.face_image.clear(); break; }
            }
        }
        if (face.face_blendshapes_count) {
            const auto& categories = face.face_blendshapes[0];
            for (unsigned int index = 0; index < categories.categories_count; ++index) {
                const auto& category = categories.categories[index];
                for (int channel = 0; channel < 52; ++channel) {
                    if (category.category_name && std::strcmp(category.category_name, face_names[channel]) == 0) output.values[522 + channel] = category.score;
                }
            }
        }
        if (face.facial_transformation_matrixes_count && face.facial_transformation_matrixes[0].rows == 4 && face.facial_transformation_matrixes[0].cols == 4) {
            output.values[3] = 1;
            const auto* matrix = face.facial_transformation_matrixes[0].data;
            for (int row = 0; row < 4; ++row) for (int column = 0; column < 4; ++column) output.values[574 + row * 4 + column] = matrix[column * 4 + row];
        }
    }
    impl->MpFaceLandmarkerCloseResult(&face);
    impl->MpHandLandmarkerCloseResult(&hands);
    impl->MpPoseLandmarkerCloseResult(&pose);
    impl->MpImageFree(image);
    if (ok) { impl->timestamp = timestamp; output.timestamp_ms = timestamp; }
    for (float value : output.values) if (!std::isfinite(value)) { impl->error = "MediaPipe returned a non-finite result"; return false; }
    return ok;
}
}
