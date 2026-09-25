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
            client.disconnect()
            isConnected = false
        } else {
            connect()
        }
    }

    private func connect() {
        currentBuffer.removeAll()
        receiveState = .json
        client.connect(
            host: "192.168.68.131",
            port: 5555,
            completionHandler: { connected, error in
                Task { @MainActor in
                    self.isConnected = connected
                    if let error {
                        self.error = error.localizedDescription
                        self.showError = true
                    }
                }
            },
            withOnReceiveData: { [weak self] data, error in
                await self?.parseReceiveBuffer(with: data, error: error)
            }
        )
    }
}

extension ClientModel {
    func parseReceiveBuffer(with data: Data, error: Error?) async {

        self.currentBuffer.append(data)

        if let error {
            self.isConnected = false
            let hasIncompleteFiles = fileTransferStore.relativePaths.values.contains {
                $0.current.type == .file && !$0.transferFinished
            }
            if fileTransferStore.relativePaths.isEmpty || hasIncompleteFiles {
                self.error = error.localizedDescription
                self.showError = true
                fileTransferStore.failIncompleteTransfer(reason: error.localizedDescription)
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
                isConnected = false
                client.disconnect()
            }
        } catch {
            print("JSON decode failed:", error)
            print("Raw JSON:", String(data: lineData, encoding: .utf8) ?? "<invalid UTF-8>")
        }
        return true
    }
}
