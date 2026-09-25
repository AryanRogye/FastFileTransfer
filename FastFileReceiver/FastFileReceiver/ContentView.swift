//
//  ContentView.swift
//  FastFileReceiver
//
//  Created by Aryan Rogye on 9/12/26.
//

import SwiftUI

struct ContentView: View {

    @State private var client = ClientModel()

    var body: some View {
        NavigationStack {
            FileTransferOutlineView(store: client.fileTransferStore)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(action: client.toggleConnection) {
                        Image(systemName: client.isConnected ? "checkmark.circle" : "xmark.circle")
                    }
                }
            }
            .alert(isPresented: $client.showError) {
                Alert(
                    title: Text("Error"),
                    message: Text("\(client.error, default: "Unknown Error")")
                )
            }
        }
    }
}

struct FileTransferOutlineView: View {
    let store: FileTransferStore

    var body: some View {
        List {
            ForEach(store.tree) { node in
                FileNodeView(node: node)
            }
        }
        .listStyle(.plain)
    }
}

struct FileNodeView: View {
    let node: FileNode

    @State private var isExpanded = true

    var body: some View {
        if node.isDirectory {
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(node.children ?? []) { child in
                    FileNodeView(node: child)
                }
            } label: {
                FileRow(node: node)
            }
        } else {
            FileRow(node: node)
        }
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
                FileProgressView(box: box)
            }
        }
    }
}

private struct FileProgressView: View {
    let box: ServerFileInfoBox

    var body: some View {
        let sent = box.current.sentBytes
        let total = box.current.totalBytes
        let isComplete = box.transferFinished

        VStack(alignment: .trailing, spacing: 2) {
            ProgressView(
                value: isComplete ? 1 : Double(sent) / Double(max(total, 1))
            )
                .progressViewStyle(.linear)
                .tint(isComplete ? .green : .blue)
                .frame(width: 80)
            Text(box.transferError ?? (isComplete ? "Complete" : "\(sent) / \(total) bytes"))
                .font(.caption2)
                .foregroundStyle(box.transferError == nil ? Color.secondary : Color.red)
        }
    }
}

#Preview {
    NavigationStack {
        ContentView()
    }
}
