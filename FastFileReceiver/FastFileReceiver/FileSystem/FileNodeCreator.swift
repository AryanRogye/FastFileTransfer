//
//  FileNodeCreator.swift
//  FastFileReceiver
//
//  Created by Aryan Rogye on 9/13/26.
//

final class FileNode: Identifiable {
    let id: String              // full relativePath, guaranteed unique
    let name: String            // just this segment
    let isDirectory: Bool
    let box: ServerFileInfoBox? // nil for synthetic folder nodes, set for real entries

    var children: [FileNode]?

    init(id: String, name: String, isDirectory: Bool, box: ServerFileInfoBox?) {
        self.id = id
        self.name = name
        self.isDirectory = isDirectory
        self.box = box
    }
}

enum FileNodeCreator {
    @MainActor
    public static func buildTree(from relativePaths: [String: ServerFileInfoBox]) -> [FileNode] {
        var root: [String: FileNode] = [:]   // path -> node, so we can find parents fast
        var topLevel: [FileNode] = []

        // sort so parent folders get created before children reference them
        let sortedBoxes = relativePaths.values.sorted {
            $0.current.relativePath < $1.current.relativePath
        }

        for box in sortedBoxes {
            let path = box.current.relativePath
            let components = path.split(separator: "/").map(String.init)

            var currentPath = ""
            var parent: FileNode?

            for (index, component) in components.enumerated() {
                currentPath = currentPath.isEmpty ? component : "\(currentPath)/\(component)"
                let isLeaf = (index == components.count - 1)

                if let existing = root[currentPath] {
                    parent = existing
                    continue
                }

                let node = FileNode(
                    id: currentPath,
                    name: component,
                    isDirectory: isLeaf ? (box.current.type == .folder) : true,
                    box: isLeaf ? box : nil
                )
                root[currentPath] = node

                if let p = parent {
                    p.children = (p.children ?? []) + [node]
                } else {
                    topLevel.append(node)
                }
                parent = node
            }
        }

        return topLevel
    }
}
