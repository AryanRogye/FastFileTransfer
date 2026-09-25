#include "FileInfo.h"
#include <cstdint>
#include <filesystem>

void walk_dir(const fs::path& path, std::uint64_t& size) {
    for (const auto& entry: fs::directory_iterator(path)) {
        if (fs::is_directory(entry)) {
            walk_dir(entry, size);
        }
        if (fs::is_regular_file(entry)) {
            size += fs::file_size(entry);
        }
    }
}

std::uint64_t FileInfo::size(const fs::path& path) {
    if (fs::is_directory(path)) {
        uint64_t size = 0;
        walk_dir(path, size);
        return size;
    }
    if (fs::is_regular_file(path)) {
        return fs::file_size(path);
    }
    return 0;
}
