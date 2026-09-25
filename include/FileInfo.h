#ifndef FILE_INFO_H
#define FILE_INFO_H

#include <cstdint>
#include <filesystem>

namespace fs = std::filesystem;

class FileInfo {
public:
    static std::uint64_t size(const fs::path& path);
};

#endif // FILE_INFO_H
