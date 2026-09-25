//
//  FileWriter.swift
//  FastFileReceiver
//
//  Created by Aryan Rogye on 9/25/26.
//

import Foundation

actor FileWriter {
    private let directory: URL
    private var dataAdded: [String: UInt64] = [:]
    private var lastProgressUpdate: [String: ContinuousClock.Instant] = [:]
    private var handles: [String: FileHandle] = [:]
    private var nextOffsets: [String: UInt64] = [:]

    enum WriteError: LocalizedError {
        case unexpectedOffset(path: String, expected: UInt64, received: UInt64)
        case exceedsFileSize(path: String)
        case incorrectFileSize(path: String, expected: UInt64, actual: UInt64)

        var errorDescription: String? {
            switch self {
            case .unexpectedOffset(let path, let expected, let received):
                "Incomplete file \(path): expected byte \(expected), received byte \(received)."
            case .exceedsFileSize(let path):
                "Received more data than expected for \(path)."
            case .incorrectFileSize(let path, let expected, let actual):
                "Incomplete file \(path): expected \(expected) bytes, saved \(actual) bytes."
            }
        }
    }

    init(directory: URL = FileManager.default.urls(
        for: .documentDirectory,
        in: .userDomainMask
    ).first!) {
        self.directory = directory
    }

    func write(
        data: Data,
        relativePath: String,
        offset: UInt64,
        totalBytes: UInt64,
        infoRelativePath: String
    ) throws -> UInt64? {
        let expectedOffset = nextOffsets[relativePath, default: 0]
        guard offset == expectedOffset else {
            throw WriteError.unexpectedOffset(path: relativePath, expected: expectedOffset, received: offset)
        }
        guard offset <= totalBytes,
              UInt64(data.count) <= totalBytes - offset else {
            throw WriteError.exceedsFileSize(path: relativePath)
        }
        let fileURL = constructFileUrl(from: infoRelativePath)
        let handle = try getFileHandle(for: relativePath, fileURL: fileURL)

        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: data)
        nextOffsets[relativePath] = offset + UInt64(data.count)

        updateDataInfo(relativePath: relativePath, data: data)

        let amountToAdd = dataAdded[relativePath, default: 0]
        let isFinished =  offset + UInt64(data.count) >= totalBytes
        let now = ContinuousClock.now
        let shouldUpdate = lastProgressUpdate[relativePath].map {
            $0.duration(to: now) >= .milliseconds(100)
        } ?? true

        if isFinished {
            removeKey(relativePath: relativePath)
            return amountToAdd;
        }
        if shouldUpdate {
            resetData(relativePath: relativePath)
            return amountToAdd
        }

        return nil
    }

    func finish(relativePath: String, fileURL: URL, expectedSize: UInt64) throws {
        if let handle = handles.removeValue(forKey: relativePath) {
            try handle.close()
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path(percentEncoded: false))
        let actualSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        guard nextOffsets[relativePath, default: 0] == expectedSize,
              actualSize == expectedSize else {
            throw WriteError.incorrectFileSize(
                path: relativePath,
                expected: expectedSize,
                actual: actualSize
            )
        }
        nextOffsets.removeValue(forKey: relativePath)
    }

    private func constructFileUrl(from relativePath: String) -> URL {
        return directory.appendingPathComponent(relativePath)
    }

    private func getFileHandle(
        for relativePath: String,
        fileURL: URL
    ) throws -> FileHandle {
        let handle: FileHandle
        if let h = handles[relativePath] {
            handle = h
        } else {
            var descriptor = open(
                fileURL.path(percentEncoded: false),
                O_WRONLY | O_CREAT,
                0o644
            )

            if descriptor == -1 && errno == ENOENT {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                descriptor = open(fileURL.path(percentEncoded: false), O_WRONLY | O_CREAT, 0o644)
            }
            guard descriptor != -1 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }

            handle = FileHandle(
                fileDescriptor: descriptor,
                closeOnDealloc: true
            )

            handles[relativePath] = handle
        }
        return handle
    }

    private func updateDataInfo(relativePath: String, data: Data) {
        dataAdded[relativePath, default: 0] += UInt64(data.count)
    }

    private func removeKey(relativePath: String) {
        dataAdded.removeValue(forKey: relativePath)
        lastProgressUpdate.removeValue(forKey: relativePath)

        if let handle = handles.removeValue(forKey: relativePath) {
            do {
                try handle.close()
            } catch {
                print("Cant Close Handle")
            }
        }
    }

    private func resetData(relativePath: String) {
        dataAdded[relativePath] = 0
        lastProgressUpdate[relativePath] = .now
    }
}
