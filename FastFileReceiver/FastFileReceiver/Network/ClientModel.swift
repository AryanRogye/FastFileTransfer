//
//  ClientModel.swift
//  FastFileReceiver
//
//  Created by Aryan Rogye on 9/24/26.
//

import Foundation

@Observable
@MainActor
final class ClientModel {
    @ObservationIgnored
    let client = Client()

    @ObservationIgnored
    private let newline = Character("\n").asciiValue!

    @ObservationIgnored
    private let structureCreator: StructureCreator


    var isConnected: Bool = false

    var error: String?
    var showError: Bool = false

    @ObservationIgnored
    private var receiveState: ReceiveState = .json
    @ObservationIgnored
    public var currentBuffer = Data()

    private(set) var fileTransferStore: FileTransferStore
    @ObservationIgnored
    private(set) var serverFileInfo: [ServerFileInfo] = []

    @ObservationIgnored
    private var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored
    private var connectionGeneration: UInt64 = 0

    private enum ReceiveState {
        case json
        case fileData(
            relativePath: String,
            offset: UInt64,
            bytesRemaining: Int
        )
    }

    init(directory: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!) {
        structureCreator = StructureCreator(directory: directory)
        fileTransferStore = FileTransferStore(directory: directory)
    }

    public func toggleConnection() {
        if isConnected {
            disconnect()
        } else {
            connect()
        }
    }

    private func disconnect(stopHeartbeat: Bool = true) {
        if stopHeartbeat {
            heartbeatTask?.cancel()
            heartbeatTask = nil
        }
        connectionGeneration &+= 1
        client.disconnect()
        isConnected = false
        currentBuffer.removeAll()
        receiveState = .json
        serverFileInfo.removeAll()
        fileTransferStore.clear()
    }

    private func connect() {
        guard !isConnected else { return }
        connectionGeneration &+= 1
        let generation = connectionGeneration
        currentBuffer.removeAll()
        receiveState = .json
        client.connect(
            host: "192.168.68.131",
            port: 5555,
            completionHandler: { connected, error in
                Task { @MainActor in
                    guard generation == self.connectionGeneration else { return }
                    self.isConnected = connected
                    if let error {
                        self.error = error.localizedDescription
                        self.showError = true
                        self.disconnect(stopHeartbeat: false)
                    }
                }
            },
            withOnReceiveData: { [weak self] data, error in
                await self?.receive(data, error: error, generation: generation)
            }
        )
        startHeartbeat()
    }

    private func receive(_ data: Data, error: Error?, generation: UInt64) async {
        guard generation == connectionGeneration else { return }
        await parseReceiveBuffer(with: data, error: error)
    }

    private func startHeartbeat() {
        guard heartbeatTask == nil else { return }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(5))
                    try Task.checkCancellation()
                    guard let self else { return }
                    if !self.isConnected {
                        self.connect()
                        print("Heartbeat")
                    }
                } catch is CancellationError {
                } catch {
                    print("Exit Hearbeat: \(error.localizedDescription)")
                    return
                }
            }
        }
    }
}

extension ClientModel {
    func parseReceiveBuffer(with data: Data, error: Error?) async {

        self.currentBuffer.append(data)

        if let error {
            let hadNoFiles = fileTransferStore.relativePaths.isEmpty
            let hasIncompleteFiles = fileTransferStore.relativePaths.values.contains {
                $0.current.type == .file && !$0.transferFinished
            }
            disconnect(stopHeartbeat: false)
            if hadNoFiles || hasIncompleteFiles {
                if let e = error as? Client.ClientError {
                    switch e {
                    case .cancelled, .invalidPort:
                        self.error = error.localizedDescription
                        self.showError = true
                    case .connectionClosed:
                        return
                    }
                }
            }
            return
        }

        while true {
            switch receiveState {
            case .json:
                guard await handleJson() else { return }
            case .fileData(let relativePath, let offset, let bytesRemaining):
                // We don't have the entire chunk yet.
                // Leave everything buffered and wait for receiveData() to append more.
                guard currentBuffer.count >= bytesRemaining else {
                    return
                }

                // Take exactly the number of raw bytes promised by the JSON header.
                let fileData = Data(currentBuffer.prefix(bytesRemaining))

                // Remove only those bytes. Anything after them may be the next JSON message.
                currentBuffer.removeFirst(bytesRemaining)

                await fileTransferStore.write(
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

    @discardableResult
    private func handleJson() async -> Bool {
        /// Look for newline delimiter '\n' (ASCII 10)
        guard let newlineIndex = currentBuffer.firstIndex(of: newline) else {
            return false
        }

        /// Current LineData is the start to the newline
        let lineData = currentBuffer.subdata(
            in: currentBuffer.startIndex..<newlineIndex
        )

        /// Remove it
        currentBuffer.removeSubrange(currentBuffer.startIndex...newlineIndex)

        do {

            /// read envelope Type
            let envelope = try JSONDecoder().decode(
                MessageEnvelope.self,
                from: lineData
            )

            switch envelope.messageType {
            case .start:
                /// On Start we remove all info on the server files
                serverFileInfo.removeAll()

            case .fileInfo:
                /// we create and add serverFileInfo's
                let fileInfo = try JSONDecoder().decode(
                    ServerFileInfo.self,
                    from: lineData
                )
                serverFileInfo.append(fileInfo)
            case .initialFileInfoMetadataDone:
                /// Once Initial is done, we can map it cleanly to a folder in the documents directory
                let mapping = await structureCreator.createInBackground(with: serverFileInfo)
                fileTransferStore.register(mapping)
            case .fileData:
                /// Once we get `fileData` this indicates that we can now start
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
                await fileTransferStore.finishTransfer()
                if let failure = fileTransferStore.relativePaths.values.compactMap(\.transferError).first {
                    self.error = failure
                    self.showError = true
                }
                receiveState = .json
            case .serverClose:
                self.error = "Server Closed"
                self.showError = true
                disconnect(stopHeartbeat: false)
            }
        } catch {
            print("JSON decode failed:", error)
            print("Raw JSON:", String(data: lineData, encoding: .utf8) ?? "<invalid UTF-8>")
        }
        return true
    }
}
