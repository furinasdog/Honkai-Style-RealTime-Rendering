#pragma once

#include <atomic>
#include <cstdint>
#include <filesystem>
#include <memory>
#include <string>
#include <vector>

namespace mocap {

struct ArchiveLimits {
    std::uint32_t max_entries = 10000;
    std::uint64_t max_archive_bytes = 2ull * 1024 * 1024 * 1024;
    std::uint64_t max_unpacked_bytes = 2ull * 1024 * 1024 * 1024;
    std::uint64_t max_file_bytes = 512ull * 1024 * 1024;
    std::uint64_t max_compression_ratio = 1000;
};

struct ArchiveEntry {
    std::uint32_t index = 0;
    std::wstring path;
    bool is_directory = false;
    std::uint64_t size = 0;
    std::uint64_t packed_size = 0;
    bool packed_size_known = false;
    bool selected = false;
    std::vector<std::wstring> aliases;
};

struct ArchiveInspection {
    std::filesystem::path archive_path;
    std::string sha256;
    std::string format;
    std::uint64_t total_unpacked = 0;
    std::vector<ArchiveEntry> entries;
    std::vector<ArchiveEntry> models;
};

struct ExtractedArchive {
    std::filesystem::path cache_root;
    std::filesystem::path index_json;
    std::vector<ArchiveEntry> models;
    std::string sha256;
};

class ArchiveService {
public:
    explicit ArchiveService(const std::filesystem::path& seven_zip_library, ArchiveLimits limits = {});
    ~ArchiveService();
    ArchiveInspection inspect(const std::filesystem::path& archive,
                              const std::atomic_bool* cancel = nullptr) const;
    ExtractedArchive extract(const std::filesystem::path& archive,
                             const std::filesystem::path& cache_directory,
                             const std::string& expected_sha256 = {},
                             const std::atomic_bool* cancel = nullptr) const;

private:
    struct Impl;
    std::shared_ptr<Impl> impl_;
    ArchiveLimits limits_;
};

}  // namespace mocap
