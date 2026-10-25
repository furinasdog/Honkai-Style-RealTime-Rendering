#include "archive_service.hpp"

#include <windows.h>
#include <bcrypt.h>
#include <objbase.h>
#include <propidl.h>
#include <winnls.h>
#include "Common/MyInitGuid.h"
#include "7zip/Archive/IArchive.h"

#include <algorithm>
#include <array>
#include <fstream>
#include <iomanip>
#include <map>
#include <set>
#include <sstream>
#include <stdexcept>
#include <utility>

namespace mocap {
namespace fs = std::filesystem;
namespace {

void check_cancel(const std::atomic_bool* cancel) {
    if (cancel && cancel->load(std::memory_order_relaxed)) throw std::runtime_error("模型导入已取消。");
}

std::string utf8(const std::wstring& value) {
    if (value.empty()) return {};
    const int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
    if (!size) throw std::runtime_error("压缩包文件名不是有效 Unicode。");
    std::string result(static_cast<std::size_t>(size), '\0');
    WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), result.data(), size, nullptr, nullptr);
    return result;
}

std::wstring folded(const std::wstring& value) {
    if (value.empty()) return {};
    const int size = LCMapStringEx(LOCALE_NAME_INVARIANT, LCMAP_LOWERCASE, value.data(), static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr, 0);
    if (!size) throw std::runtime_error("无法规范化模型文件名。");
    std::wstring result(static_cast<std::size_t>(size), L'\0');
    LCMapStringEx(LOCALE_NAME_INVARIANT, LCMAP_LOWERCASE, value.data(), static_cast<int>(value.size()), result.data(), size, nullptr, nullptr, 0);
    return result;
}

std::wstring safe_name(std::wstring name, bool directory) {
    // 7-Zip maps Unix ZIP backslashes to WSL's private-use escape before exposing names.
    std::replace(name.begin(), name.end(), static_cast<wchar_t>(0xf05c), L'/');
    std::replace(name.begin(), name.end(), L'\\', L'/');
    if (directory && !name.empty() && name.back() == L'/') name.pop_back();
    if (name.empty() || name.front() == L'/' || name.size() > 4096) throw std::runtime_error("压缩包包含无效或绝对路径。");
    const int normalized_size = NormalizeString(NormalizationC, name.data(), static_cast<int>(name.size()), nullptr, 0);
    if (normalized_size <= 0) throw std::runtime_error("压缩包文件名不是有效 Unicode。");
    std::wstring normalized(static_cast<std::size_t>(normalized_size), L'\0');
    const int written = NormalizeString(NormalizationC, name.data(), static_cast<int>(name.size()), normalized.data(), normalized_size);
    if (written <= 0) throw std::runtime_error("压缩包文件名不是有效 Unicode。");
    normalized.resize(static_cast<std::size_t>(written));
    std::size_t start = 0;
    while (start <= normalized.size()) {
        const auto end = normalized.find(L'/', start);
        const auto part = normalized.substr(start, end == std::wstring::npos ? std::wstring::npos : end - start);
        if (part.empty() || part == L"." || part == L".." || part.back() == L' ' || part.back() == L'.') throw std::runtime_error("压缩包包含越界或无效路径。");
        for (const wchar_t ch : part) {
            if (ch < 32 || ch == 127 || ch == L':' || ch == L'<' || ch == L'>' || ch == L'"' || ch == L'|' || ch == L'?' || ch == L'*') throw std::runtime_error("压缩包包含无效的 Windows 文件路径。");
        }
        auto stem = folded(part.substr(0, part.find(L'.')));
        while (!stem.empty() && stem.back() == L' ') stem.pop_back();
        if (stem == L"con" || stem == L"prn" || stem == L"aux" || stem == L"nul" || stem == L"conin$" || stem == L"conout$" ||
            (stem.size() == 4 && (stem.substr(0, 3) == L"com" || stem.substr(0, 3) == L"lpt") &&
             ((stem[3] >= L'0' && stem[3] <= L'9') || stem[3] == 0x00b9 || stem[3] == 0x00b2 || stem[3] == 0x00b3))) throw std::runtime_error("压缩包包含 Windows 保留文件名。");
        if (end == std::wstring::npos) break;
        start = end + 1;
    }
    return normalized;
}

bool allowed_file(const std::wstring& name) {
    static const std::set<std::wstring> extensions{L".pmx", L".png", L".jpg", L".jpeg", L".bmp", L".tga", L".dds", L".tif", L".tiff", L".webp", L".sph", L".spa"};
    return extensions.count(folded(fs::path(name).extension().wstring())) != 0;
}

std::string json_string(const std::string& value) {
    std::ostringstream out;
    out << '"';
    for (const unsigned char ch : value) {
        if (ch == '"' || ch == '\\') out << '\\' << static_cast<char>(ch);
        else if (ch < 32) out << "\\u00" << std::hex << std::setw(2) << std::setfill('0') << static_cast<unsigned>(ch) << std::dec;
        else out << static_cast<char>(ch);
    }
    out << '"';
    return out.str();
}

struct Prop {
    PROPVARIANT value{};
    ~Prop() { PropVariantClear(&value); }
    Prop(const Prop&) = delete;
    Prop& operator=(const Prop&) = delete;
    Prop() = default;
    bool boolean() const { return value.vt == VT_BOOL && value.boolVal != VARIANT_FALSE; }
    std::uint64_t number(std::uint64_t fallback = 0) const {
        if (value.vt == VT_UI8) return value.uhVal.QuadPart;
        if (value.vt == VT_UI4) return value.ulVal;
        if (value.vt == VT_UI2) return value.uiVal;
        return fallback;
    }
    std::wstring text() const { return value.vt == VT_BSTR && value.bstrVal ? std::wstring(value.bstrVal, SysStringLen(value.bstrVal)) : std::wstring(); }
};

template<class T> struct ComPtr {
    T* value = nullptr;
    ~ComPtr() { if (value) value->Release(); }
    T* operator->() const { return value; }
};

#define ARCHIVE_REFCOUNT \
    ULONG STDMETHODCALLTYPE AddRef() noexcept override { return ++references_; } \
    ULONG STDMETHODCALLTYPE Release() noexcept override { const ULONG count = --references_; if (!count) delete this; return count; }

class InputStream final : public IInStream {
public:
    InputStream(const fs::path& path, const std::atomic_bool* cancel) : cancel_(cancel) {
        handle_ = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
        if (handle_ == INVALID_HANDLE_VALUE) throw std::runtime_error("无法读取压缩包，文件可能正在被其他程序写入。");
    }
    ~InputStream() { CloseHandle(handle_); }
    ARCHIVE_REFCOUNT
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** out) noexcept override {
        *out = nullptr;
        if (iid == IID_IUnknown || iid == IID_IInStream || iid == IID_ISequentialInStream) *out = static_cast<IInStream*>(this);
        if (!*out) return E_NOINTERFACE;
        AddRef(); return S_OK;
    }
    HRESULT STDMETHODCALLTYPE Read(void* data, UInt32 size, UInt32* processed) noexcept override {
        if (processed) *processed = 0;
        if (cancel_ && cancel_->load(std::memory_order_relaxed)) return E_ABORT;
        DWORD bytes = 0;
        if (!ReadFile(handle_, data, size, &bytes, nullptr)) return HRESULT_FROM_WIN32(GetLastError());
        if (processed) *processed = bytes;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE Seek(Int64 offset, UInt32 origin, UInt64* position) noexcept override {
        LARGE_INTEGER input{}, output{}; input.QuadPart = offset;
        if (!SetFilePointerEx(handle_, input, &output, origin)) return HRESULT_FROM_WIN32(GetLastError());
        if (position) *position = static_cast<UInt64>(output.QuadPart);
        return S_OK;
    }
    std::uint64_t size() const {
        LARGE_INTEGER result{};
        if (!GetFileSizeEx(handle_, &result) || result.QuadPart < 0) throw std::runtime_error("无法读取压缩包大小。");
        return static_cast<std::uint64_t>(result.QuadPart);
    }
private:
    HANDLE handle_ = INVALID_HANDLE_VALUE;
    std::atomic<ULONG> references_{1};
    const std::atomic_bool* cancel_;
};

std::string file_sha256(InputStream& stream, const std::atomic_bool* cancel) {
    BCRYPT_ALG_HANDLE algorithm = nullptr;
    BCRYPT_HASH_HANDLE hash = nullptr;
    std::vector<unsigned char> object;
    if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) < 0) throw std::runtime_error("无法初始化压缩包校验。");
    struct Cleanup { BCRYPT_ALG_HANDLE algorithm; BCRYPT_HASH_HANDLE& hash; ~Cleanup() { if (hash) BCryptDestroyHash(hash); BCryptCloseAlgorithmProvider(algorithm, 0); } } cleanup{algorithm, hash};
    DWORD object_size = 0, result_size = 0;
    if (BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH, reinterpret_cast<PUCHAR>(&object_size), sizeof(object_size), &result_size, 0) < 0) throw std::runtime_error("无法初始化压缩包校验。");
    object.resize(object_size);
    std::vector<unsigned char> bytes(1024 * 1024);
    if (BCryptCreateHash(algorithm, &hash, object.data(), object_size, nullptr, 0, 0) < 0) throw std::runtime_error("无法初始化压缩包校验。");
    stream.Seek(0, STREAM_SEEK_SET, nullptr);
    for (;;) {
        check_cancel(cancel);
        UInt32 count = 0;
        if (stream.Read(bytes.data(), static_cast<UInt32>(bytes.size()), &count) != S_OK) throw std::runtime_error("压缩包校验读取失败。");
        if (!count) break;
        if (BCryptHashData(hash, bytes.data(), count, 0) < 0) throw std::runtime_error("压缩包校验失败。");
    }
    std::array<unsigned char, 32> digest{};
    if (BCryptFinishHash(hash, digest.data(), static_cast<ULONG>(digest.size()), 0) < 0) throw std::runtime_error("压缩包校验失败。");
    stream.Seek(0, STREAM_SEEK_SET, nullptr);
    std::ostringstream text;
    for (const auto byte : digest) text << std::hex << std::setw(2) << std::setfill('0') << static_cast<unsigned>(byte);
    return text.str();
}

class OpenProgress final : public IArchiveOpenCallback {
public:
    explicit OpenProgress(const std::atomic_bool* cancel) : cancel_(cancel) {}
    ARCHIVE_REFCOUNT
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** out) noexcept override {
        *out = nullptr;
        if (iid == IID_IUnknown || iid == IID_IArchiveOpenCallback) *out = static_cast<IArchiveOpenCallback*>(this);
        if (!*out) return E_NOINTERFACE;
        AddRef(); return S_OK;
    }
    HRESULT STDMETHODCALLTYPE SetTotal(const UInt64*, const UInt64*) noexcept override { return active(); }
    HRESULT STDMETHODCALLTYPE SetCompleted(const UInt64*, const UInt64*) noexcept override { return active(); }
private:
    HRESULT active() const { return cancel_ && cancel_->load(std::memory_order_relaxed) ? E_ABORT : S_OK; }
    std::atomic<ULONG> references_{1};
    const std::atomic_bool* cancel_;
};

int name_score(const std::wstring& name) {
    int score = 0;
    for (const auto ch : name) {
        if (ch >= 0x3040 && ch <= 0x30ff) score += 4;
        else if (ch >= 0xff61 && ch <= 0xff9f) score -= 6;
        else if (ch >= 0x4e00 && ch <= 0x9fff) ++score;
    }
    return score;
}

std::vector<std::wstring> entry_names(IInArchive* archive, UInt32 index, bool directory, bool zip) {
    auto read = [&]() {
        Prop value;
        if (archive->GetProperty(index, kpidPath, &value.value) != S_OK) throw std::runtime_error("压缩包目录读取失败。");
        return value.text();
    };
    ComPtr<ISetProperties> properties;
    if (!zip || archive->QueryInterface(IID_ISetProperties, reinterpret_cast<void**>(&properties.value)) != S_OK) return {safe_name(read(), directory)};
    auto read_page = [&](ULONG page) {
        const wchar_t* key = L"cp";
        Prop value; value.value.vt = VT_UI4; value.value.ulVal = page;
        if (properties->SetProperties(&key, &value.value, 1) != S_OK) throw std::runtime_error("ZIP 文件名编码设置失败。");
        return read();
    };
    const auto name_utf8 = read_page(CP_UTF8);
    const auto name_gbk = read_page(936);
    const auto name_sjis = read_page(932);
    auto name_oem = read_page(437);
    // Unicode extra fields and the ZIP UTF-8 flag take precedence over every forced page.
    if (name_utf8 == name_gbk && name_utf8 == name_sjis && name_utf8 == name_oem) return {safe_name(name_utf8, directory)};
    std::replace(name_oem.begin(), name_oem.end(), static_cast<wchar_t>(0xf05c), L'\\');
    BOOL substituted = FALSE;
    const int raw_size = WideCharToMultiByte(437, WC_NO_BEST_FIT_CHARS, name_oem.data(), static_cast<int>(name_oem.size()), nullptr, 0, nullptr, &substituted);
    std::string raw(static_cast<std::size_t>(std::max(raw_size, 0)), '\0');
    if (raw_size > 0 && !substituted) WideCharToMultiByte(437, WC_NO_BEST_FIT_CHARS, name_oem.data(), static_cast<int>(name_oem.size()), raw.data(), raw_size, nullptr, &substituted);
    std::vector<std::wstring> names;
    auto add = [&](std::wstring name) {
        try { name = safe_name(std::move(name), directory); }
        catch (const std::exception&) { return false; }
        if (std::find(names.begin(), names.end(), name) == names.end()) names.push_back(std::move(name));
        return true;
    };
    if (raw_size > 0 && !substituted) {
        for (const UINT page : std::array<UINT, 4>{CP_UTF8, 936, 932, 437}) {
            const int count = MultiByteToWideChar(page, MB_ERR_INVALID_CHARS, raw.data(), raw_size, nullptr, 0);
            if (!count) continue;
            std::wstring name(static_cast<std::size_t>(count), L'\0');
            MultiByteToWideChar(page, MB_ERR_INVALID_CHARS, raw.data(), raw_size, name.data(), count);
            if (add(std::move(name)) && page == CP_UTF8) return names;
        }
    } else {
        add(name_gbk); add(name_sjis); add(name_oem);
    }
    std::stable_sort(names.begin(), names.end(), [](const auto& a, const auto& b) { return name_score(a) > name_score(b); });
    if (names.empty()) throw std::runtime_error("压缩包包含越界、保留名称或无法解析的文件路径。");
    return names;
}
struct OpenedArchive {
    ComPtr<InputStream> stream;
    ComPtr<IInArchive> archive;
    ArchiveInspection inspection;
    ~OpenedArchive() { if (archive.value) archive->Close(); }
};

void get_archive_property(IInArchive* archive, PROPID id, Prop& out) {
    if (archive->GetArchiveProperty(id, &out.value) != S_OK) throw std::runtime_error("无法读取压缩包属性。");
}

void get_property(IInArchive* archive, UInt32 index, PROPID id, Prop& out) {
    if (archive->GetProperty(index, id, &out.value) != S_OK) throw std::runtime_error("无法读取压缩包文件属性。");
}

void inspect_opened(OpenedArchive& opened, const ArchiveLimits& limits, const std::atomic_bool* cancel) {
    auto& inspection = opened.inspection;
    auto* archive = opened.archive.value;
    for (const auto id : {kpidIsVolume, kpidEncrypted}) {
        Prop property; get_archive_property(archive, id, property);
        if (property.boolean()) throw std::runtime_error("不支持分卷或加密压缩包。");
    }
    for (const auto id : {kpidNumVolumes, kpidErrorFlags}) {
        Prop property; get_archive_property(archive, id, property);
        if ((id == kpidNumVolumes && property.number() > 1) || (id == kpidErrorFlags && property.number())) throw std::runtime_error("压缩包已损坏或使用了不支持的分卷格式。");
    }
    UInt32 count = 0;
    if (archive->GetNumberOfItems(&count) != S_OK || count > limits.max_entries) throw std::runtime_error("压缩包超过10000项限制。");
    std::map<std::wstring, bool> paths;
    std::map<std::wstring, std::wstring> aliases;
    for (UInt32 index = 0; index < count; ++index) {
        check_cancel(cancel);
        ArchiveEntry entry; entry.index = index;
        Prop directory; get_property(archive, index, kpidIsDir, directory); entry.is_directory = directory.boolean();
        for (const auto id : {kpidEncrypted, kpidSplitBefore, kpidSplitAfter, kpidIsAltStream, kpidIsAnti}) {
            Prop property; get_property(archive, index, id, property);
            if (property.boolean()) throw std::runtime_error("不支持加密、分卷或特殊压缩包条目。");
        }
        for (const auto id : {kpidSymLink, kpidHardLink}) {
            Prop property; get_property(archive, index, id, property);
            if (!property.text().empty()) throw std::runtime_error("压缩包不能包含链接。");
        }
        Prop attributes; get_property(archive, index, kpidAttrib, attributes);
        if (attributes.number() & FILE_ATTRIBUTE_REPARSE_POINT) throw std::runtime_error("压缩包不能包含重解析点。");
        Prop posix; get_property(archive, index, kpidPosixAttrib, posix);
        const auto type = posix.number() & 0170000;
        if (type && type != 0100000 && type != 0040000) throw std::runtime_error("压缩包不能包含链接或特殊文件。");
        entry.aliases = entry_names(archive, index, entry.is_directory, inspection.format == "zip");
        entry.path = entry.aliases.front();
        const auto key = folded(entry.path);
        const auto old = paths.find(key);
        if (old != paths.end() && (!entry.is_directory || !old->second)) throw std::runtime_error("压缩包包含重复或大小写冲突的路径。");
        paths[key] = entry.is_directory;
        Prop size; get_property(archive, index, kpidSize, size); entry.size = size.number();
        Prop packed; get_property(archive, index, kpidPackSize, packed);
        entry.packed_size_known = packed.value.vt == VT_UI8 || packed.value.vt == VT_UI4;
        entry.packed_size = packed.number();
        if (!entry.is_directory) {
            if (size.value.vt != VT_UI8 && size.value.vt != VT_UI4) throw std::runtime_error("压缩包没有可靠的文件大小。");
            if (entry.size > limits.max_file_bytes || entry.size > limits.max_unpacked_bytes - inspection.total_unpacked) throw std::runtime_error("解压后大小超过限制：单文件512 MiB，总计2 GiB。");
            inspection.total_unpacked += entry.size;
            if (entry.packed_size_known && ((inspection.format == "zip" && entry.size && !entry.packed_size) ||
                (entry.packed_size && (entry.size / entry.packed_size > limits.max_compression_ratio ||
                 (entry.size / entry.packed_size == limits.max_compression_ratio && entry.size % entry.packed_size))))) throw std::runtime_error("压缩包文件的压缩率超出限制。");
            entry.selected = allowed_file(entry.path);
            if (entry.selected) {
                for (const auto& alias : entry.aliases) {
                    const auto alias_key = folded(alias);
                    if (aliases.count(alias_key) && aliases.at(alias_key) != entry.path) throw std::runtime_error("压缩包存在编码冲突的文件路径。");
                    aliases[alias_key] = entry.path;
                }
                if (folded(fs::path(entry.path).extension().wstring()) == L".pmx") inspection.models.push_back(entry);
            }
        }
        inspection.entries.push_back(std::move(entry));
    }
    const auto archive_bytes = std::max<std::uint64_t>(opened.stream->size(), 1);
    if (inspection.total_unpacked / archive_bytes > limits.max_compression_ratio ||
        (inspection.total_unpacked / archive_bytes == limits.max_compression_ratio && inspection.total_unpacked % archive_bytes)) throw std::runtime_error("压缩包总压缩率超出限制。");
    for (const auto& entry : inspection.entries) {
        auto parent = fs::path(entry.path).parent_path();
        while (!parent.empty()) {
            const auto old = paths.find(folded(parent.generic_wstring()));
            if (old != paths.end() && !old->second) throw std::runtime_error("压缩包存在文件和目录路径冲突。");
            parent = parent.parent_path();
        }
    }
    if (inspection.models.empty()) throw std::runtime_error("压缩包内没有 PMX 模型。");
    std::sort(inspection.models.begin(), inspection.models.end(), [](const auto& a, const auto& b) { return folded(a.path) < folded(b.path); });
}

void reject_reparse(const fs::path& path) {
    const auto attributes = GetFileAttributesW(path.c_str());
    if (attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_REPARSE_POINT)) throw std::runtime_error("模型缓存路径不能包含链接或重解析点。");
}

void make_parent_directories(const fs::path& root, const fs::path& relative) {
    auto current = root;
    for (const auto& component : relative.parent_path()) {
        current /= component;
        reject_reparse(current);
        fs::create_directory(current);
    }
}

struct ExtractState {
    const ArchiveInspection& inspection;
    const ArchiveLimits& limits;
    fs::path staging;
    const std::atomic_bool* cancel;
    std::atomic<std::uint64_t> written{0};
    std::string error;
};

class OutputStream final : public ISequentialOutStream {
public:
    OutputStream(const fs::path& path, std::uint64_t expected, ExtractState& state) : expected_(expected), state_(state) {
        handle_ = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
        if (handle_ == INVALID_HANDLE_VALUE) throw std::runtime_error("无法创建模型缓存文件。");
    }
    ~OutputStream() { CloseHandle(handle_); }
    ARCHIVE_REFCOUNT
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** out) noexcept override {
        *out = nullptr;
        if (iid == IID_IUnknown || iid == IID_ISequentialOutStream) *out = static_cast<ISequentialOutStream*>(this);
        if (!*out) return E_NOINTERFACE;
        AddRef(); return S_OK;
    }
    HRESULT STDMETHODCALLTYPE Write(const void* data, UInt32 size, UInt32* processed) noexcept override {
        if (processed) *processed = 0;
        if (state_.cancel && state_.cancel->load(std::memory_order_relaxed)) return E_ABORT;
        if (size > expected_ - written_ || size > state_.limits.max_unpacked_bytes - state_.written.load()) return E_ABORT;
        DWORD bytes = 0;
        if (!WriteFile(handle_, data, size, &bytes, nullptr)) return HRESULT_FROM_WIN32(GetLastError());
        written_ += bytes;
        state_.written.fetch_add(bytes);
        if (processed) *processed = bytes;
        return S_OK;
    }
private:
    HANDLE handle_ = INVALID_HANDLE_VALUE;
    std::atomic<ULONG> references_{1};
    std::uint64_t expected_, written_ = 0;
    ExtractState& state_;
};

class ExtractCallback final : public IArchiveExtractCallback {
public:
    explicit ExtractCallback(ExtractState& state) : state_(state) {}
    ARCHIVE_REFCOUNT
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** out) noexcept override {
        *out = nullptr;
        if (iid == IID_IUnknown || iid == IID_IArchiveExtractCallback || iid == IID_IProgress) *out = static_cast<IArchiveExtractCallback*>(this);
        if (!*out) return E_NOINTERFACE;
        AddRef(); return S_OK;
    }
    HRESULT STDMETHODCALLTYPE SetTotal(UInt64) noexcept override { return active(); }
    HRESULT STDMETHODCALLTYPE SetCompleted(const UInt64*) noexcept override { return active(); }
    HRESULT STDMETHODCALLTYPE PrepareOperation(Int32) noexcept override { return active(); }
    HRESULT STDMETHODCALLTYPE GetStream(UInt32 index, ISequentialOutStream** output, Int32 mode) noexcept override {
        *output = nullptr;
        if (active() != S_OK) return E_ABORT;
        if (mode != NArchive::NExtract::NAskMode::kExtract) return S_OK;
        try {
            const auto& entry = state_.inspection.entries.at(index);
            if (!entry.selected || entry.is_directory) return S_OK;
            const fs::path relative(entry.path);
            make_parent_directories(state_.staging, relative);
            *output = new OutputStream(state_.staging / relative, entry.size, state_);
            return S_OK;
        } catch (const std::exception& error) { state_.error = error.what(); return E_FAIL; }
    }
    HRESULT STDMETHODCALLTYPE SetOperationResult(Int32 result) noexcept override {
        if (result != NArchive::NExtract::NOperationResult::kOK) {
            state_.error = "压缩包 CRC 校验或数据解码失败。";
            return E_FAIL;
        }
        return active();
    }
private:
    HRESULT active() const { return state_.cancel && state_.cancel->load(std::memory_order_relaxed) ? E_ABORT : S_OK; }
    std::atomic<ULONG> references_{1};
    ExtractState& state_;
};

bool cache_complete(const fs::path& directory, const ArchiveInspection& inspection) {
    reject_reparse(directory);
    reject_reparse(directory / "archive_index.json");
    if (!fs::is_regular_file(directory / "archive_index.json")) return false;
    for (const auto& entry : inspection.entries) if (entry.selected) {
        auto current = directory;
        for (const auto& component : fs::path(entry.path)) { current /= component; reject_reparse(current); }
        if (!fs::is_regular_file(current) || fs::file_size(current) != entry.size) return false;
    }
    return true;
}

void write_index(const fs::path& destination, const fs::path& final_directory, const ArchiveInspection& inspection) {
    std::ofstream out(destination, std::ios::binary | std::ios::trunc);
    if (!out) throw std::runtime_error("无法写入模型缓存索引。");
    out << "{\"ok\":true,\"format\":" << json_string(inspection.format) << ",\"archive\":" << json_string(utf8(inspection.archive_path.generic_wstring()))
        << ",\"sha256\":" << json_string(inspection.sha256) << ",\"cache_root\":" << json_string(utf8(final_directory.generic_wstring())) << ",\"models\":[";
    bool comma = false;
    for (const auto& model : inspection.models) {
        if (comma) out << ',';
        comma = true;
        out << "{\"path\":" << json_string(utf8(model.path)) << ",\"name\":" << json_string(utf8(fs::path(model.path).stem().wstring())) << '}';
    }
    out << "],\"aliases\":{";
    std::map<std::wstring, std::wstring> aliases;
    for (const auto& entry : inspection.entries) if (entry.selected) for (const auto& alias : entry.aliases) aliases[folded(alias)] = entry.path;
    comma = false;
    for (const auto& alias : aliases) {
        if (comma) out << ',';
        comma = true;
        out << json_string(utf8(alias.first)) << ':' << json_string(utf8(alias.second));
    }
    out << "}}\n";
    out.close();
    if (!out) throw std::runtime_error("模型缓存索引写入失败。");
}

}  // namespace

struct ArchiveService::Impl {
    HMODULE library = nullptr;
    Func_CreateObject create = nullptr;
    explicit Impl(const fs::path& path) {
        library = LoadLibraryExW(fs::absolute(path).c_str(), nullptr, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
        if (!library) throw std::runtime_error("无法加载随包 7z.dll，请重新解压完整发布包。");
        create = reinterpret_cast<Func_CreateObject>(GetProcAddress(library, "CreateObject"));
        if (!create) { FreeLibrary(library); library = nullptr; throw std::runtime_error("7z.dll 缺少归档接口。"); }
    }
    ~Impl() { if (library) FreeLibrary(library); }
    void open(OpenedArchive& opened, const fs::path& path, const ArchiveLimits& limits, const std::atomic_bool* cancel) const {
        check_cancel(cancel);
        auto& inspection = opened.inspection;
        inspection.archive_path = fs::canonical(path);
        const auto extension = folded(inspection.archive_path.extension().wstring());
        if (extension != L".zip" && extension != L".7z") throw std::runtime_error("请选择 ZIP 或 7z 压缩包；暂不支持 RAR、分卷或加密包。");
        inspection.format = extension == L".zip" ? "zip" : "7z";
        opened.stream.value = new InputStream(inspection.archive_path, cancel);
        if (opened.stream->size() > limits.max_archive_bytes) throw std::runtime_error("压缩包大小超过2 GiB限制。");
        inspection.sha256 = file_sha256(*opened.stream.value, cancel);
        const GUID format{0x23170f69, 0x40c1, 0x278a, {0x10, 0x00, 0x00, 0x01, 0x10, static_cast<unsigned char>(extension == L".zip" ? 1 : 7), 0x00, 0x00}};
        if (create(&format, &IID_IInArchive, reinterpret_cast<void**>(&opened.archive.value)) != S_OK || !opened.archive.value) throw std::runtime_error("7z.dll 不支持所选格式。");
        ComPtr<OpenProgress> progress; progress.value = new OpenProgress(cancel);
        const UInt64 search_offset = 0;
        if (opened.archive->Open(opened.stream.value, &search_offset, progress.value) != S_OK) {
            check_cancel(cancel);
            throw std::runtime_error("无法打开压缩包，文件可能损坏、加密或属于分卷。");
        }
        inspect_opened(opened, limits, cancel);
    }
};

ArchiveService::ArchiveService(const fs::path& library, ArchiveLimits limits) : impl_(std::make_shared<Impl>(library)), limits_(limits) {}
ArchiveService::~ArchiveService() = default;

ArchiveInspection ArchiveService::inspect(const fs::path& archive, const std::atomic_bool* cancel) const {
    OpenedArchive opened;
    impl_->open(opened, archive, limits_, cancel);
    return opened.inspection;
}

ExtractedArchive ArchiveService::extract(const fs::path& archive, const fs::path& cache_directory,
                                        const std::string& expected_sha256, const std::atomic_bool* cancel) const {
    OpenedArchive opened;
    impl_->open(opened, archive, limits_, cancel);
    const auto& inspection = opened.inspection;
    if (!expected_sha256.empty() && expected_sha256 != inspection.sha256) throw std::runtime_error("压缩包在选择模型后发生变化，请重新导入。");
    fs::create_directories(cache_directory);
    const auto cache = fs::canonical(cache_directory);
    const auto destination = cache / inspection.sha256.substr(0, 24);
    if (fs::exists(destination)) {
        if (!cache_complete(destination, inspection)) throw std::runtime_error("模型缓存已存在但不完整，请移除该缓存后重试。");
        check_cancel(cancel);
        return {destination, destination / "archive_index.json", inspection.models, inspection.sha256};
    }
    GUID id{};
    if (CoCreateGuid(&id) != S_OK) throw std::runtime_error("无法创建模型导入临时目录。");
    wchar_t text[40]{}; StringFromGUID2(id, text, 40);
    const auto staging = cache / (std::wstring(L"extract-") + text);
    if (!fs::create_directory(staging)) throw std::runtime_error("无法创建模型导入临时目录。");
    struct StagingCleanup { fs::path directory; bool active = true; ~StagingCleanup() { if (active) { std::error_code ignored; fs::remove_all(directory, ignored); } } } cleanup{staging};
    ExtractState state{inspection, limits_, staging, cancel};
    ComPtr<ExtractCallback> callback; callback.value = new ExtractCallback(state);
    std::vector<UInt32> indices;
    for (const auto& entry : inspection.entries) if (entry.selected) indices.push_back(entry.index);
    const auto result = opened.archive->Extract(indices.data(), static_cast<UInt32>(indices.size()), 0, callback.value);
    check_cancel(cancel);
    if (result != S_OK || !state.error.empty()) throw std::runtime_error(state.error.empty() ? "模型压缩包解压失败。" : state.error);
    for (const auto& entry : inspection.entries) if (entry.selected) {
        const auto path = staging / fs::path(entry.path);
        if (!fs::is_regular_file(path) || fs::file_size(path) != entry.size) throw std::runtime_error("模型解压结果的文件大小不匹配。");
    }
    write_index(staging / "archive_index.json", destination, inspection);
    check_cancel(cancel);
    fs::rename(staging, destination);
    cleanup.active = false;
    return {destination, destination / "archive_index.json", inspection.models, inspection.sha256};
}

}  // namespace mocap
