//
//  StructureCreatorTests.swift
//  FastFileReceiver
//
//  Created by Aryan Rogye on 9/13/26.
//

import Testing
import Foundation
import FastFileReceiver

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

    @Test func makeStructure() {
        print(FileManager.default.temporaryDirectory.path())
//        guard let folder = structureCreator.create(with: serverFileInfo) else {
//            assert(false)
//        }
    }
}
