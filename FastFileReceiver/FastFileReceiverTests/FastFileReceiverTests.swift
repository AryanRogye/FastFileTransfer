//
//  FastFileReceiverTests.swift
//  FastFileReceiverTests
//
//  Created by Aryan Rogye on 9/12/26.
//

import Foundation
import Testing
@testable import FastFileReceiver

struct FastFileReceiverTests {

    @Test @MainActor func splitMetadataMessage() async {
        let model = ClientModel()
        let message = """
        {"messageType":"fileInfo","type":"file","pathLength":14,"sentBytes":0,"totalBytes":3,"relativePath":"Transfer/a.txt"}

        """
        let bytes = Data(message.utf8)
        let midpoint = bytes.count / 2

        await model.parseReceiveBuffer(with: Data(bytes.prefix(midpoint)), error: nil)
        #expect(model.serverFileInfo.isEmpty)

        await model.parseReceiveBuffer(with: Data(bytes.dropFirst(midpoint)), error: nil)
        #expect(model.serverFileInfo.count == 1)
        #expect(model.serverFileInfo.first?.relativePath == "Transfer/a.txt")
    }

    @Test @MainActor func largeTransferThroughParser() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = ClientModel(directory: directory)
        let size = 99_042_826
        let metadata = """
        {"messageType":"start"}
        {"messageType":"fileInfo","type":"file","pathLength":14,"sentBytes":0,"totalBytes":\(size),"relativePath":"Transfer/a.bin"}
        {"messageType":"initialFileInfoMetadataDone"}

        """
        let start = ContinuousClock.now
        await model.parseReceiveBuffer(with: Data(metadata.utf8), error: nil)
        let payload = Data((0..<1_048_576).map { UInt8(truncatingIfNeeded: $0) })
        var offset = 0
        while offset < size {
            let count = min(payload.count, size - offset)
            let header = "{\"messageType\":\"fileData\",\"relativePath\":\"Transfer/a.bin\",\"offset\":\(offset),\"bytesRead\":\(count)}\n"
            var wire = Data(header.utf8)
            wire.append(payload.prefix(count))
            // Reproduce Network.framework's 64 KiB delivery and split headers/payloads.
            for position in stride(from: 0, to: wire.count, by: 65_536) {
                await model.parseReceiveBuffer(with: wire.subdata(in: position..<min(position + 65_536, wire.count)), error: nil)
            }
            offset += count
        }
        await model.parseReceiveBuffer(with: Data("{\"messageType\":\"finalFileInfoMetadataDone\"}\n".utf8), error: nil)
        print("RECEIVER_BENCHMARK 99042826 bytes: \(start.duration(to: .now))")
        let box = try #require(model.fileTransferStore.box(for: "Transfer/a.bin"))
        #expect(box.current.sentBytes == UInt64(size))
        let received = try Data(contentsOf: directory.appendingPathComponent(box.current.relativePath))
        #expect(received.count == size)
        #expect(received.prefix(payload.count) == payload)
        #expect(received.suffix(size % payload.count) == payload.prefix(size % payload.count))
    }

    @Test @MainActor func incompleteVideoIsReported() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = ClientModel(directory: directory)
        let metadata = """
        {"messageType":"start"}
        {"messageType":"fileInfo","type":"file","pathLength":18,"sentBytes":0,"totalBytes":6,"relativePath":"Transfer/video.mov"}
        {"messageType":"initialFileInfoMetadataDone"}

        """
        await model.parseReceiveBuffer(with: Data(metadata.utf8), error: nil)
        let chunk = "{\"messageType\":\"fileData\",\"relativePath\":\"Transfer/video.mov\",\"offset\":0,\"bytesRead\":3}\nabc"
        await model.parseReceiveBuffer(with: Data(chunk.utf8), error: nil)
        await model.parseReceiveBuffer(with: Data("{\"messageType\":\"finalFileInfoMetadataDone\"}\n".utf8), error: nil)

        let box = try #require(model.fileTransferStore.box(for: "Transfer/video.mov"))
        #expect(!box.transferFinished)
        #expect(box.transferError != nil)
    }

    // Opt in with TEST_RUNNER_TRANSFER_BENCHMARK_HOST when running xcodebuild.
    // The diagnostic sender must serve the normal transfer protocol on port 5556.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRANSFER_BENCHMARK_HOST"] != nil))
    @MainActor func networkTransferBenchmark() async throws {
        let host = try #require(ProcessInfo.processInfo.environment["TRANSFER_BENCHMARK_HOST"])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = ClientModel(directory: directory)
        let client = Client()
        defer { client.disconnect() }
        let start = ContinuousClock.now
        let port = UInt16(ProcessInfo.processInfo.environment["TRANSFER_BENCHMARK_PORT"] ?? "5556") ?? 5556
        let receivedData = AsyncStream<Data> { continuation in
            client.connect(
                host: host,
                port: port,
                completionHandler: { connected, _ in
                    if !connected { continuation.finish() }
                },
                withOnReceiveData: { data, _ in
                    continuation.yield(data)
                }
            )
        }
        var wireBytes = 0
        for await data in receivedData {
            wireBytes += data.count
            await model.parseReceiveBuffer(with: data, error: nil)
            if !model.fileTransferStore.relativePaths.isEmpty,
               model.fileTransferStore.relativePaths.values.allSatisfy({ $0.transferFinished }) {
                break
            }
        }
        print("NETWORK_BENCHMARK \(wireBytes) wire bytes: \(start.duration(to: .now))")
        #expect(!model.fileTransferStore.relativePaths.isEmpty)
        for box in model.fileTransferStore.relativePaths.values where box.current.type == .file {
            #expect(box.current.sentBytes == box.current.totalBytes)
            let received = try Data(contentsOf: directory.appendingPathComponent(box.current.relativePath))
            #expect(UInt64(received.count) == box.current.totalBytes)
            if port == 5556 {
                #expect(received.allSatisfy { $0 == 42 })
            }
        }
    }

}
