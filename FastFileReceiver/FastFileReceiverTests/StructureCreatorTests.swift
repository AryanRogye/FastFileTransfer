//
//  StructureCreatorTests.swift
//  FastFileReceiver
//
//  Created by Aryan Rogye on 9/13/26.
//

import Testing
import Foundation
@testable import FastFileReceiver

struct StructureCreatorTests {

    let structureCreator = StructureCreator(
        directory: FileManager.default.temporaryDirectory
    )

    let serverFileInfo: [ServerFileInfo] = [
        ServerFileInfo(
            messageType: .fileInfo,
            type: .folder,
            pathLength: 12,
            sentBytes: 0,
            totalBytes: 0,
            relativePath: "MyTransfer/"
        ),
        ServerFileInfo(
            messageType: .fileInfo,
            type: .folder,
            pathLength: 19,
            sentBytes: 0,
            totalBytes: 0,
            relativePath: "MyTransfer/Photos/"
        ),
        ServerFileInfo(
            messageType: .fileInfo,
            type: .file,
            pathLength: 30,
            sentBytes: 0,
            totalBytes: 4_194_304,
            relativePath: "MyTransfer/Photos/logo.png"
        ),
        ServerFileInfo(
            messageType: .fileInfo,
            type: .file,
            pathLength: 35,
            sentBytes: 0,
            totalBytes: 20_971_520,
            relativePath: "MyTransfer/Videos/demo_final.mov"
        ),
        ServerFileInfo(
            messageType: .fileInfo,
            type: .file,
            pathLength: 21,
            sentBytes: 0,
            totalBytes: 512,
            relativePath: "MyTransfer/notes.txt"
        )
    ]

    @Test @MainActor func makeStructure() async {
        let mapping = structureCreator.create(with: serverFileInfo)
        defer {
            if let root = mapping[serverFileInfo[0]] {
                let rootURL = structureCreator.directory.appendingPathComponent(root.relativePath)
                try? FileManager.default.removeItem(at: rootURL)
            }
        }

        #expect(mapping.count == serverFileInfo.count)
        for info in serverFileInfo {
            guard let destination = mapping[info] else {
                Issue.record("Missing destination for \(info.relativePath)")
                continue
            }
            let url = structureCreator.directory.appendingPathComponent(destination.relativePath)
            #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        }

        let store = FileTransferStore(directory: structureCreator.directory)
        store.register(mapping)
        let payload = Data([0, 10, 255, 42])
        await store.write(
            data: payload,
            relativePath: "MyTransfer/Photos/logo.png",
            offset: 0
        )
        if let destination = mapping[serverFileInfo[2]] {
            let url = structureCreator.directory.appendingPathComponent(destination.relativePath)
            let received = try? Data(contentsOf: url)
            #expect(received == payload)
            #expect(store.box(for: "MyTransfer/Photos/logo.png")?.current.sentBytes == 4)
        }
    }
    @Test func writerPublishesFirstWriteAndFlushesCompletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = FileWriter(directory: directory)
        let first = try await writer.write(
            data: Data([0, 10]), relativePath: "a.bin", offset: 0,
            totalBytes: 4, infoRelativePath: "nested/a.bin"
        )
        #expect(first == 2)
        let last = try await writer.write(
            data: Data([255, 42]), relativePath: "a.bin", offset: 2,
            totalBytes: 4, infoRelativePath: "nested/a.bin"
        )
        #expect(last == 2)
        let received = try Data(contentsOf: directory.appendingPathComponent("nested/a.bin"))
        #expect(received == Data([0, 10, 255, 42]))
    }

    @Test @MainActor func fileNamesWithSpacesUseDecodedDiskPaths() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = ServerFileInfo(
            messageType: .fileInfo, type: .file, pathLength: 26,
            sentBytes: 0, totalBytes: 4,
            relativePath: "Transfer/Video copy.mp4"
        )
        let mapping = StructureCreator(directory: directory).create(with: [original])
        let destination = try #require(mapping[original])
        let store = FileTransferStore(directory: directory)
        store.register(mapping)
        await store.write(data: Data([0, 10, 255, 42]), relativePath: original.relativePath, offset: 0)
        await store.finishTransfer()

        let savedURL = directory.appendingPathComponent(destination.relativePath)
        #expect(try Data(contentsOf: savedURL) == Data([0, 10, 255, 42]))
        #expect(store.box(for: original.relativePath)?.transferFinished == true)
        #expect(!FileManager.default.fileExists(atPath: savedURL.path(percentEncoded: true)))
    }

}
