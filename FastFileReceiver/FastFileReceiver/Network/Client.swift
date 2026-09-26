//
//  Client.swift
//  FastFileReceiver
//
//  Created by Aryan Rogye on 9/12/26.
//

import Network
import Foundation

/// What the file tpye of what we're receiving
public nonisolated enum NodeType: String, Codable, Sendable {
    case file = "file"
    case folder = "folder"
}

public struct FileDataInfo: Codable {
    let messageType: MessageType
    let relativePath: String
    let offset: UInt64
    let bytesRead: Int
}

public nonisolated struct ServerFileInfo: Codable, Identifiable, Hashable, Sendable {

    public var id: String { relativePath }

    let messageType: MessageType
    let type: NodeType
    let pathLength: UInt32
    var sentBytes: UInt64
    let totalBytes: UInt64
    let relativePath: String

    public init(messageType: MessageType, type: NodeType, pathLength: UInt32, sentBytes: UInt64, totalBytes: UInt64, relativePath: String) {
        self.messageType = messageType
        self.type = type
        self.pathLength = pathLength
        self.sentBytes = sentBytes
        self.totalBytes = totalBytes
        self.relativePath = relativePath
    }
}

public struct MessageEnvelope: Codable {
    let messageType: MessageType
}

final class Client {

    private var connection: NWConnection?
    private let newline = Character("\n").asciiValue!

    private var startingDataLoad: Bool = false
    private var onReceiveData: ((Data, Error?) async -> Void)?

    private var didDisconnect: Bool = true

    enum ClientError: LocalizedError {
        case invalidPort
        case cancelled
        case connectionClosed

        var errorDescription: String? {
            switch self {
            case .invalidPort:
                "Invalid Port"
            case .cancelled:
                "Cancelled"
            case .connectionClosed:
                "Connection closed before the transfer finished"
            }
        }
    }

    public func disconnect() {
        self.didDisconnect = true
        self.connection?.cancel()
        self.connection = nil
    }

    public func connect(
        host: String,
        port: UInt16,
        completionHandler: @escaping(Bool, Error?) -> Void = { _, _ in },
        withOnReceiveData: @escaping(Data, Error?) async -> Void = { _, _ in }
    ) {
        didDisconnect = false
        let host = NWEndpoint.Host(host)
        guard let port = NWEndpoint.Port(rawValue: port) else {
            completionHandler(false, ClientError.invalidPort)
            return
        }

        let connection = NWConnection(
            host: host,
            port: port,
            using: .tcp
        )

        self.connection = connection
        self.onReceiveData = withOnReceiveData

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }

            switch state {
            case .ready:
                completionHandler(true, nil)
                receiveData()

            case .failed(let error):
                if didDisconnect { return }
                completionHandler(false, error)

            case .cancelled:
                if didDisconnect { return }
                completionHandler(false, ClientError.cancelled)

            case .waiting(let error):
                if let nsError = error as NSError?, nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ECONNREFUSED) {
                    completionHandler(false, nil)
                }

            case .setup:
                print("Setting up connection")

            case .preparing:
                print("Preparing connection")

            @unknown default:
                break
            }
        }

        connection.start(queue: .global())
    }

    private func receiveData() {
        connection?.receive(
            minimumIncompleteLength: 1,
            maximumLength: 65536
        ) { [weak self] data, context, isComplete, error in
            guard let self else { return }

            Task {
                if let data, !data.isEmpty {
                    await self.onReceiveData?(data, nil)
                }

                if let error {
                    await self.onReceiveData?(Data(), error)
                    return
                }

                if isComplete {
                    let didDisconnect = await MainActor.run { self.didDisconnect }
                    if !didDisconnect {
                        await self.onReceiveData?(Data(), ClientError.connectionClosed)
                    }
                } else {
                    await MainActor.run {
                        self.receiveData()
                    }
                }
            }
        }
    }
}
