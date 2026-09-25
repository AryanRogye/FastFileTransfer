# FastFileTransfer

This is a personal project I built to practice C++. It explores filesystem traversal, TCP networking, threads, and sending file data in chunks. The sender is written in C++ and the receiver is a small SwiftUI app for Apple platforms.

This is a learning project, not a finished file transfer tool. Some parts are rough, and there are bugs and edge cases I still need to work through. I am sharing it to show what I am learning and building, not as production-ready software.

## What it does

- Scans a folder and builds a list of its files and subfolders.
- Starts a TCP server on port `5555` and accepts receiver connections.
- Sends file metadata and data to connected clients.
- Shows received files and transfer progress in the SwiftUI app.

## Building the C++ sender

You need a C++17 compiler, CMake 3.21 or newer, and Git. CMake downloads Asio and nlohmann/json during configuration.

```sh
cmake -S . -B build
cmake --build build
./build/FastFileTransfer /path/to/folder
```

You can also run the executable without an argument and enter a folder path at the prompt. After starting the server, choose option `3` in its menu to send the folder to connected clients.

## Running the receiver

Open `FastFileReceiver/FastFileReceiver.xcodeproj` in Xcode and run the app. Before connecting, change the default host address in `FastFileReceiver/FastFileReceiver/Network/Client.swift` to the sender computer's local IP address. The app connects to port `5555` when you tap the connection button.

The sender and receiver should be on the same trusted local network. Transfers use plain TCP with no authentication or encryption, so do not expose the server port to the internet or use it for sensitive files.

## Current limitations

- The receiver address is hardcoded in the app.
- The protocol and error handling are still experimental.
- Transfer correctness and recovery have not been fully tested across different files and network conditions.

I plan to keep improving this as I practice C++.
