#ifndef FOLDER_INFO_H
#define FOLDER_INFO_H

#include <filesystem>

namespace fs = std::filesystem;

enum NodeType {
    file,
    folder
};

inline std::string nodeTypeToString(NodeType type) {
    switch (type) {
        case file:
            return "file";
        case folder:
            return "folder";
    }
}

struct BreadthFileNode {
    std::string name;
    NodeType type;
    std::string relativePath;
};

class FolderInfo {
public:
    FolderInfo(fs::path folderPath);
    BreadthFileNode generate();
    
    std::vector<std::vector<BreadthFileNode>> getLevels() const;
private:
    std::vector<std::vector<BreadthFileNode>> levels;
    fs::path folderPath;
};

#endif // FOLDER_INFO_H
