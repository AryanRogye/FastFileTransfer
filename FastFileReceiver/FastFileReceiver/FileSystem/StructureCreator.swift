//
//  StructureCreator.swift
//  FastFileReceiver
//
//  Created by Aryan Rogye on 9/13/26.
//

import Foundation

public nonisolated final class StructureCreator: Sendable {

    let directory: URL

    public init(directory: URL = FileManager.default.urls(
        for: .documentDirectory,
        in: .userDomainMask
    ).first!) {
        self.directory = directory
    }

    @concurrent
    public func createInBackground(with serverFileInfo: [ServerFileInfo]) async -> [ServerFileInfo: ServerFileInfo] {
        create(with: serverFileInfo)
    }

    public func create(with serverFileInfo: [ServerFileInfo]) -> [ServerFileInfo: ServerFileInfo] {
        /// we'll create a UUID string
        let id = UUID().uuidString
        guard let rootFolder = serverFileInfo.first?.relativePath.split(separator: "/").first else {
            return [:]
        }

        /// we'll make a folder with this info:
        let mainFolderUrl = "\(rootFolder)-\(id)"

        /// We'll update the server file info with this new folder name
        let modifiedServerFileInfos: [ServerFileInfo] = serverFileInfo.map { file in
            let components = file.relativePath.split(separator: "/")

            let newPath = ([mainFolderUrl] + components.dropFirst().map(String.init))
                .joined(separator: "/")

            return ServerFileInfo(
                messageType: file.messageType,
                type: file.type,
                pathLength: UInt32(newPath.utf8.count),
                sentBytes: file.sentBytes,
                totalBytes: file.totalBytes,
                relativePath: newPath
            )
        }

        let folderURL = directory.appendingPathComponent(mainFolderUrl)
        do {
            try FileManager.default.createDirectory(
                at: folderURL,
                withIntermediateDirectories: true
            )
        } catch {
            print("Error Creating Root Folder: \(error.localizedDescription)")
            return [:]
        }

        // A directory only needs to be prepared once, even with thousands of siblings.
        var createdDirectories: Set<URL> = [folderURL]
        func ensureDirectory(_ url: URL) throws {
            guard !createdDirectories.contains(url) else { return }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            createdDirectories.insert(url)
        }

        var result: [ServerFileInfo: ServerFileInfo] = [:]
        for i in 0..<modifiedServerFileInfos.count {
            let modifiedServerFileInfo = modifiedServerFileInfos[i]
            let url = directory.appendingPathComponent(modifiedServerFileInfo.relativePath)

            result[serverFileInfo[i]] = modifiedServerFileInfo

            if modifiedServerFileInfo.type == .folder {
                do {
                    try ensureDirectory(url)
                } catch {
                    print("Error Creating Directory: \(error.localizedDescription)")
                    try? FileManager.default.removeItem(at: folderURL)
                    return [:]
                }
            } else if modifiedServerFileInfo.type == .file {
                do {
                    try ensureDirectory(url.deletingLastPathComponent())
                    guard FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                } catch {
                    print("Error creating file \(url.path(percentEncoded: false)): \(error)")
                    try? FileManager.default.removeItem(at: folderURL)
                    return [:]
                }
            }
        }

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: folderURL.path(percentEncoded: false), isDirectory: &isDirectory) {
            if !isDirectory.boolValue {
                return [:]
            }
            return result
        }
        return [:]
    }
}
