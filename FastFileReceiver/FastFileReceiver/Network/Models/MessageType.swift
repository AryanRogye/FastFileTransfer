//
//  MessageType.swift
//  FastFileReceiver
//
//  Created by Aryan Rogye on 9/25/26.
//

/// What kind of message the server is sending us
/// The server will send this to us to see what we're doing
public nonisolated enum MessageType: String, Codable, Sendable {
    case start
    case fileInfo
    case initialFileInfoMetadataDone
    case fileData
    case finalFileInfoMetadataDone
    case serverClose
}
