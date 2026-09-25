//
//  FileTransferStore.swift
//  FastFileReceiver
//
//  Created by Aryan Rogye on 9/13/26.
//

import Foundation
import Darwin

@Observable
@MainActor
final class ServerFileInfoBox: Identifiable {
    var id: String { current.relativePath }

    var current: ServerFileInfo
    var transferFinished = false
    var transferError: String?

    init(_ info: ServerFileInfo) {
        self.current = info
    }
}

@Observable
final class FileTransferStore {

    @ObservationIgnored
    private let directory: URL

    @ObservationIgnored
    let fileWriter: FileWriter

    private(set) var relativePaths: [String: ServerFileInfoBox] = [:]
    private(set) var tree: [FileNode] = []

    init(directory: URL = FileManager.default.urls(
        for: .documentDirectory,
        in: .userDomainMask
    ).first!) {
        self.directory = directory
        self.fileWriter = FileWriter(directory: directory)
    }

    func register(_ mapping: [ServerFileInfo: ServerFileInfo]) {
        for (original, modified) in mapping {
            let box = ServerFileInfoBox(modified)
            relativePaths[original.relativePath] = box
        }
        tree = FileNodeCreator.buildTree(from: relativePaths)
    }

    func write(data: Data, relativePath: String, offset: UInt64) async {
        guard let info = relativePaths[relativePath],
              info.current.type == .file else { return }

        let totalBytes = info.current.totalBytes
        let infoRelativePath = info.current.relativePath

        do {
            if let amount = try await self.fileWriter.write(
                data: data,
                relativePath: relativePath,
                offset: offset,
                totalBytes: totalBytes,
                infoRelativePath: infoRelativePath
            ) {
                info.current.sentBytes += amount
            }
        } catch {
            info.transferError = error.localizedDescription
        }
    }

    func box(for relativePath: String) -> ServerFileInfoBox? {
        return relativePaths[relativePath]
    }

    func finishTransfer() async {
        for box in relativePaths.values where box.current.type == .folder {
            box.transferFinished = true
        }
        for (originalPath, box) in relativePaths where box.current.type == .file {
            guard box.transferError == nil else { continue }
            do {
                try await fileWriter.finish(
                    relativePath: originalPath,
                    fileURL: directory.appendingPathComponent(box.current.relativePath),
                    expectedSize: box.current.totalBytes
                )
                box.current.sentBytes = box.current.totalBytes
                box.transferFinished = true
            } catch {
                box.transferError = error.localizedDescription
            }
        }
    }

    func failIncompleteTransfer(reason: String) {
        for box in relativePaths.values where box.current.type == .file && !box.transferFinished {
            box.transferError = box.transferError ?? reason
        }
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
