//
//  Client.swift
//  FastFileReceiver
//
//  Created by Aryan Rogye on 9/12/26.
//

import Network
import Foundation

/// What the file tpye of what we're receiving
public enum NodeType: String, Codable {
    case file = "file"
    case folder = "folder"
}

/// What kind of message the server is sending us
public enum MessageType: String, Codable {
    case start
    case fileInfo
    case initialFileInfoMetadataDone
    case startingDataLoad
    case fileData
    case finalFileInfoMetadataDone
}

public struct FileDataInfo: Codable {
    let messageType: MessageType
    let relativePath: String
    let offset: UInt64
    let bytesRead: Int
}

public struct ServerFileInfo: Codable, Identifiable, Hashable {

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

@Observable
@MainActor
final class ClientModel {
    @ObservationIgnored
    private let client = Client()
}

@Observable
final class Client {

    private enum ReceiveState {
        case json
        case fileData(
            relativePath: String,
            offset: UInt64,
            bytesRemaining: Int
        )
    }

    @ObservationIgnored
    private var connection: NWConnection?
    @ObservationIgnored
    private var receiveBuffer = Data()
    @ObservationIgnored
    private var structureCreator = StructureCreator()

    private(set) var fileTransferStore: FileTransferStore = .init()
    private(set) var serverFileInfo: [ServerFileInfo] = []
    private(set) var isConnected: Bool = false
    private(set) var connectionError: String? = nil
    var showError: Bool = false

    private(set) var lastMessageType: MessageType?
    private let newline = Character("\n").asciiValue!

    private var startingDataLoad: Bool = false
    private var receiveState: ReceiveState = .json

    private enum ClientError: LocalizedError {
        case invalidPort
        case cancelled

        var errorDescription: String? {
            switch self {
            case .invalidPort:
                "Invalid Port"
            case .cancelled:
                "Cancelled"
            }
        }
    }

    public func connect(
        host: String = "192.168.68.131",
        port: UInt16 = 5555,
        completionHandler: @escaping(Bool, Error?) -> Void = { _, _ in }
    ) {

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

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                completionHandler(true, nil)
                isConnected = true
                connectionError = nil
                receiveData()
            case .failed(let reason):
                completionHandler(false, reason)
                isConnected = false
                connectionError = reason.localizedDescription
                showError = true
            case .cancelled:
                completionHandler(false, ClientError.cancelled)
                isConnected = false
                connectionError = "Cancelled"
                showError = true
            default:
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
            if let data, !data.isEmpty {
                receiveBuffer.append(data)
                parseReceiveBuffer()
            }

            if let error = error {
                print("Receive error: \(error)")
                return
            }

            // Continue listening for the next chunk of data
            if !isComplete {
                self.receiveData()
            }
        }
    }

    private func parseReceiveBuffer() {
        while true {
            switch receiveState {
            case .json:
                // Look for newline delimiter '\n' (ASCII 10)
                guard let newlineIndex = receiveBuffer.firstIndex(of: newline) else {
                    return
                }

                let lineData = receiveBuffer.subdata(
                    in: receiveBuffer.startIndex..<newlineIndex
                )
                // Remove the line + the newline character from the buffer
                receiveBuffer.removeSubrange(receiveBuffer.startIndex...newlineIndex)

                do {
                    let envelope = try JSONDecoder().decode(
                        MessageEnvelope.self,
                        from: lineData
                    )

                    switch envelope.messageType {
                    case .start:
                        serverFileInfo.removeAll()

                    case .fileInfo:
                        let fileInfo = try JSONDecoder().decode(
                            ServerFileInfo.self,
                            from: lineData
                        )
                        serverFileInfo.append(fileInfo)
                    case .initialFileInfoMetadataDone:
                        let mapping = structureCreator.create(with: serverFileInfo)
                        fileTransferStore.register(mapping)
                    case .startingDataLoad:
                        startingDataLoad = true
                    case .fileData:
                        let fileDataInfo = try JSONDecoder().decode(
                            FileDataInfo.self,
                            from: lineData
                        )

                        receiveState = .fileData(
                            relativePath: fileDataInfo.relativePath,
                            offset: fileDataInfo.offset,
                            bytesRemaining: fileDataInfo.bytesRead
                        )
                    case .finalFileInfoMetadataDone:
                        startingDataLoad = false
                    }
                } catch {

                }

            case .fileData(let relativePath, let offset, let bytesRemaining):
                // We don't have the entire chunk yet.
                // Leave everything buffered and wait for receiveData() to append more.
                guard receiveBuffer.count >= bytesRemaining else {
                    return
                }

                // Take exactly the number of raw bytes promised by the JSON header.
                let fileData = Data(receiveBuffer.prefix(bytesRemaining))

                // Remove only those bytes. Anything after them may be the next JSON message.
                receiveBuffer.removeFirst(bytesRemaining)

                // TODO: Write fileData to relativePath at offset.
                fileTransferStore.write(
                    data: fileData,
                    relativePath: relativePath,
                    offset: offset
                )

                // The binary payload is finished.
                // The next bytes in receiveBuffer are protocol JSON again.
                receiveState = .json
            }
        }
    }
}
