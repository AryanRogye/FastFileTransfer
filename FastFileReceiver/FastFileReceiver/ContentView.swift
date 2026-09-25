//
//  ContentView.swift
//  FastFileReceiver
//
//  Created by Aryan Rogye on 9/12/26.
//

import SwiftUI

struct ContentView: View {

    @State private var client = Client()

    var body: some View {
        NavigationStack {
            FileTransferOutlineView(store: client.fileTransferStore)
            .toolbar {
                ToolbarItem(placement: .status) {
                    if let type = client.lastMessageType {
                        Text(type.rawValue)
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if client.isConnected {
                        Image(systemName: "checkmark.circle")
                    }
                    Button(action: { client.connect() }) {
                        Image(systemName: "cable.connector.horizontal")
                    }
                    .disabled(client.isConnected)
                }
            }
            .alert(isPresented: $client.showError) {
                Alert(
                    title: Text("Error"),
                    message: Text("\(client.connectionError, default: "Unknown Error")")
                )
            }
        }
    }
}

struct FileTransferOutlineView: View {
    let store: FileTransferStore

    var body: some View {
        List {
            OutlineGroup(store.tree, id: \.id, children: \.children) { node in
                FileRow(node: node)
            }
        }
        .listStyle(.plain)
    }
}

struct FileRow: View {
    let node: FileNode

    var body: some View {
        HStack {
            Image(systemName: node.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(node.isDirectory ? .blue : .gray)
            Text(node.name)
            Spacer()
            if let box = node.box, box.current.type == .file {
                ProgressView(
                    value: Double(min(box.current.sentBytes, box.current.totalBytes)),
                    total: Double(max(box.current.totalBytes, 1))
                )
                .frame(width: 60)
            }
        }
    }
}

#Preview {
    ContentView()
}
