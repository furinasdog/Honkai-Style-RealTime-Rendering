#include "archive_service.hpp"
#include <windows.h>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <vector>
#include <string>

namespace fs = std::filesystem;

void require(bool condition, const char* message) { if (!condition) throw std::runtime_error(message); }

struct ZipEntry {
    std::string name;
    std::string data = "PMX fixture";
    unsigned flags = 0x800;
    unsigned attributes = 0100644u << 16;
    std::uint32_t declared_size = 0;
};

void put16(std::ostream& out, unsigned value) { out.put(static_cast<char>(value)); out.put(static_cast<char>(value >> 8)); }
void put32(std::ostream& out, std::uint32_t value) { put16(out, value & 65535); put16(out, value >> 16); }

std::uint32_t crc32(const std::string& data) {
    std::uint32_t crc = 0xffffffff;
    for (const unsigned char byte : data) {
        crc ^= byte;
        for (int bit = 0; bit < 8; ++bit) crc = (crc >> 1) ^ (0xedb88320u & (0u - (crc & 1)));
    }
    return ~crc;
}

void zip(const fs::path& path, const std::vector<ZipEntry>& entries) {
    std::ofstream out(path, std::ios::binary);
    std::vector<std::uint32_t> offsets;
    for (const auto& entry : entries) {
        offsets.push_back(static_cast<std::uint32_t>(out.tellp()));
        const auto actual = static_cast<std::uint32_t>(entry.data.size());
        const auto size = entry.declared_size ? entry.declared_size : actual;
        put32(out, 0x04034b50); put16(out, 20); put16(out, entry.flags); put16(out, 0); put16(out, 0); put16(out, 0);
        put32(out, crc32(entry.data)); put32(out, actual); put32(out, size); put16(out, static_cast<unsigned>(entry.name.size())); put16(out, 0);
        out.write(entry.name.data(), static_cast<std::streamsize>(entry.name.size())); out.write(entry.data.data(), static_cast<std::streamsize>(entry.data.size()));
    }
    const auto central = static_cast<std::uint32_t>(out.tellp());
    for (std::size_t index = 0; index < entries.size(); ++index) {
        const auto& entry = entries[index];
        const auto actual = static_cast<std::uint32_t>(entry.data.size());
        const auto size = entry.declared_size ? entry.declared_size : actual;
        put32(out, 0x02014b50); put16(out, 0x0314); put16(out, 20); put16(out, entry.flags); put16(out, 0); put16(out, 0); put16(out, 0);
        put32(out, crc32(entry.data)); put32(out, actual); put32(out, size); put16(out, static_cast<unsigned>(entry.name.size())); put16(out, 0); put16(out, 0);
        put16(out, 0); put16(out, 0); put32(out, entry.attributes); put32(out, offsets[index]); out.write(entry.name.data(), static_cast<std::streamsize>(entry.name.size()));
    }
    const auto end = static_cast<std::uint32_t>(out.tellp());
    put32(out, 0x06054b50); put16(out, 0); put16(out, 0); put16(out, static_cast<unsigned>(entries.size())); put16(out, static_cast<unsigned>(entries.size()));
    put32(out, end - central); put32(out, central); put16(out, 0);
}

template<class Function> void rejects(Function&& action, const char* message) {
    bool failed = false;
    try { action(); } catch (const std::exception&) { failed = true; }
    require(failed, message);
}

int wmain(int count, wchar_t** args) {
    try {
        require(count >= 3, "Usage: archive_service_tests 7z.dll evidence-directory [actual-model.zip]");
        const fs::path evidence = fs::absolute(args[2]);
        fs::create_directories(evidence);
        mocap::ArchiveService service(fs::absolute(args[1]));
        const auto archive = evidence / L"模型 with spaces.zip";
        zip(archive, {{u8"模型/三月七.pmx"}, {u8"模型/贴图.png", "texture"}, {"weapon.pmx"}, {"evil.py", "must not extract"}});
        const auto inspection = service.inspect(archive);
        require(inspection.models.size() == 2, "Model selection must list all PMX entries");
        const auto extracted = service.extract(archive, evidence / L"缓存 with spaces", inspection.sha256);
        require(fs::exists(extracted.cache_root / L"模型/三月七.pmx"), "Unicode model path was not extracted");
        require(fs::exists(extracted.cache_root / L"模型/贴图.png"), "Unicode texture was not extracted");
        require(!fs::exists(extracted.cache_root / "evil.py"), "Archive script was extracted");
        require(fs::exists(extracted.index_json), "Compatible index JSON was not written");
        const auto cached = service.extract(archive, evidence / L"缓存 with spaces", inspection.sha256);
        require(cached.cache_root == extracted.cache_root, "Content-addressed cache should be reusable");
        rejects([&] { service.extract(archive, evidence / "changed", "not-the-current-hash"); }, "Stale inspected archive hash was accepted");

        const auto invalid = evidence / "invalid.zip";
        for (const auto& path : {"../escape.pmx", "C:/escape.pmx", "/escape.pmx", "folder/../escape.pmx", "NUL.pmx", "CON .pmx", "file.pmx:stream", "folder\\..\\escape.pmx"}) {
            zip(invalid, {{path}});
            const auto description = std::string("Unsafe archive path was accepted: ") + path;
            rejects([&] { service.extract(invalid, evidence / "invalid-cache"); }, description.c_str());
        }
        zip(invalid, {{"A.pmx"}, {"a.pmx"}});
        rejects([&] { service.inspect(invalid); }, "Case collision was accepted");
        zip(invalid, {{"link.pmx", "../outside", 0x800, 0120777u << 16}});
        rejects([&] { service.inspect(invalid); }, "Symlink was accepted");
        zip(invalid, {{"encrypted.pmx", "bytes", 0x801}});
        rejects([&] { service.inspect(invalid); }, "Encrypted entry was accepted");
        zip(invalid, {{"bomb.pmx", "x", 0x800, 0100644u << 16, 1024 * 1024}});
        rejects([&] { service.inspect(invalid); }, "Compression bomb was accepted");
        zip(invalid, {{"empty.txt", "text"}});
        rejects([&] { service.inspect(invalid); }, "Archive without PMX was accepted");
        zip(invalid, {{"ok.pmx"}, {"second.pmx"}});
        mocap::ArchiveLimits small; small.max_entries = 1;
        mocap::ArchiveService limited(fs::absolute(args[1]), small);
        rejects([&] { limited.inspect(invalid); }, "Entry count limit was ignored");
        zip(invalid, {{"damaged.pmx", "PMX original contents"}});
        {
            std::fstream corrupt(invalid, std::ios::binary | std::ios::in | std::ios::out);
            corrupt.seekp(30 + static_cast<std::streamoff>(std::string("damaged.pmx").size()));
            corrupt.put('X');
        }
        rejects([&] { service.extract(invalid, evidence / "crc-failure"); }, "CRC-damaged payload was accepted");
        for (const auto& item : fs::recursive_directory_iterator(evidence / "crc-failure")) require(item.path().filename() != "archive_index.json", "Failed extraction was published");
        std::atomic_bool cancelled{true};
        rejects([&] { service.extract(archive, evidence / "cancelled", {}, &cancelled); }, "Cancellation was ignored");

        for (const auto& encoding : {std::pair<UINT, std::wstring>{936, L"模型/三月七.pmx"}, {932, L"モデル/初音ミク.pmx"}}) {
            const int bytes = WideCharToMultiByte(encoding.first, WC_NO_BEST_FIT_CHARS, encoding.second.data(), static_cast<int>(encoding.second.size()), nullptr, 0, nullptr, nullptr);
            std::string name(static_cast<std::size_t>(bytes), '\0');
            WideCharToMultiByte(encoding.first, WC_NO_BEST_FIT_CHARS, encoding.second.data(), static_cast<int>(encoding.second.size()), name.data(), bytes, nullptr, nullptr);
            zip(invalid, {{name, "PMX encoded", 0}});
            const auto result = service.inspect(invalid);
            require(result.models.front().path == encoding.second, "Legacy Chinese/Japanese ZIP path decoding failed");
        }
        if (count > 3) {
            const auto real = service.extract(fs::absolute(args[3]), evidence / L"真实角色缓存");
            require(!real.models.empty(), "Actual model archive produced no PMX candidates");
            std::cout << "REAL_MODEL_INDEX " << real.index_json.u8string() << '\n';
        }
        std::cout << "ARCHIVE_SERVICE_PASS Unicode, selection, whitelist, cache, stale hash, path traversal, collision, symlink, encryption, limits, cancellation, legacy names\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "ARCHIVE_SERVICE_FAIL " << error.what() << '\n';
        return 1;
    }
}
