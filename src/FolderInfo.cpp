#include "FolderInfo.h"
#include <cstddef>
#include <filesystem>
#include <iostream>
#include <sys/fcntl.h>
#include <vector>

struct PathInfo {
    fs::path path;
    std::string relativePath;
};

std::vector<PathInfo> parse(
    const fs::path& path, 
    std::vector<BreadthFileNode>& level, 
    const fs::path& relativePath
) {
    std::vector<PathInfo> nextDirectoriesToScan;

    for (const auto& entry : fs::directory_iterator(path)) {
        
        std::string name = entry.path().filename().string();
        fs::path fullPath = fs::path(relativePath) / entry.path().filename();

        if (fs::is_directory(entry)) {
            nextDirectoriesToScan.push_back({ 
                entry.path(),
                fullPath
            });
            BreadthFileNode folderNode = {
                name,
                NodeType::folder,
                fullPath
            };
            level.push_back(folderNode);
        }
        if (fs::is_regular_file(entry)) {
            BreadthFileNode fileNode = {
                name,
                NodeType::file,
                fullPath
            };
            level.push_back(fileNode);
        }
    }

    return nextDirectoriesToScan;
}

void loadLevels(
    const std::vector<PathInfo>& infos,
    std::vector<std::vector<BreadthFileNode>>& levels
) {
    if (infos.empty()) {
        return;
    }
    std::vector<PathInfo> nextIteratorInfos;
    std::vector<BreadthFileNode> level;
    for (const auto& info: infos) {
        std::vector<BreadthFileNode> nextLevels;
        for (const auto& infos: parse(info.path, nextLevels, info.relativePath)) {
            nextIteratorInfos.push_back(infos);
        }
        for (const auto& nextLevel: nextLevels) {
            level.push_back(nextLevel);
        }
    }
    levels.push_back(level);
    loadLevels(nextIteratorInfos, levels);
}

FolderInfo::FolderInfo(fs::path folderPath): folderPath(folderPath) 
{}

std::vector<std::vector<BreadthFileNode>> FolderInfo::getLevels() const {
    return this->levels;
}

BreadthFileNode FolderInfo::generate() {
    BreadthFileNode node = {
        folderPath.stem().string(),
        NodeType::folder,
        folderPath.stem().string()
    };

    this->levels.push_back({ node });
    std::vector<BreadthFileNode> level;
    std::vector<PathInfo> infos = parse(folderPath, level, node.relativePath);
    this->levels.push_back(level);

    loadLevels(infos, this->levels);

    // for(std::size_t i = 0; i < levels.size(); i++) {
    //     for (std::size_t j = 0; j < levels[i].size(); j++) {
    //         std::cout << "[" << i << "] " << levels[i][j].relativePath << std::endl;
    //     }
    // }

    return node;
}
