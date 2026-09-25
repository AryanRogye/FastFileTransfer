//
//  FileTransferStore.swift
//  FastFileReceiver
//
//  Created by Aryan Rogye on 9/13/26.
//

import Foundation

@Observable
@MainActor
final class ServerFileInfoBox: Identifiable {
    var id: String { current.relativePath }

    var current: ServerFileInfo

    init(_ info: ServerFileInfo) {
        self.current = info
    }
}

@Observable
@MainActor
final class FileTransferStore {

    private(set) var relativePaths: [String: ServerFileInfoBox] = [:]
    private(set) var tree: [FileNode] = []

    func register(_ mapping: [ServerFileInfo: ServerFileInfo]) {
        for (original, modified) in mapping {
            let box = ServerFileInfoBox(modified)
            relativePaths[original.relativePath] = box
        }
        tree = FileNodeCreator.buildTree(from: relativePaths)
    }

    func write(data: Data, relativePath: String, offset: UInt64) {
        guard let info = relativePaths[relativePath],
              info.current.type == .file,
              let documentsURL = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
              ).first else { return }

        let fileURL = documentsURL.appendingPathComponent(info.current.relativePath)

        do {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: offset)
            try handle.write(contentsOf: data)
            info.current.sentBytes += UInt64(data.count)
        } catch {
            print("Error writing \(fileURL.lastPathComponent): \(error)")
        }
    }

    func box(for relativePath: String) -> ServerFileInfoBox? {
        return relativePaths[relativePath]
    }

    func updateProgress(relativePath: String, sentBytes: UInt64, totalBytes: UInt64) {
        guard let box = relativePaths[relativePath] else { return }
        box.current = ServerFileInfo(
            messageType: box.current.messageType,
            type: box.current.type,
            pathLength: box.current.pathLength,
            sentBytes: sentBytes,
            totalBytes: totalBytes,
            relativePath: box.current.relativePath
        )
    }
}
