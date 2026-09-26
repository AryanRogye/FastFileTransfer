#include "Server.h"
#include <FileInfo.h>
#include <FolderInfo.h>
#include <asio/impl/read_until.hpp>
#include <asio/signal_set.hpp>
#include <asio/socket_base.hpp>
#include <asio/write.hpp>
#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <future>
#include <ios>
#include <iostream>
#include <nlohmann/json.hpp>
#include <stddef.h>
#include <stdexcept>
#include <system_error>
#include <unordered_map>
#include <vector>

using json = nlohmann::json;

ClientIdentity create_identity(const asio::ip::tcp::socket& client) {
    asio::ip::tcp::endpoint remote_endpoint = client.remote_endpoint();
    ClientIdentity identity = {
        remote_endpoint.address().to_string(),
        remote_endpoint.port()
    };
    return identity;
}

Server::Server(): acceptor(io) {}

Server::~Server() {
    this->stopServer();
}

void Server::startServer() {
    if(serverThread.joinable()) {
        return;
    }

    asio::ip::tcp::endpoint endpoint(
        asio::ip::tcp::v4(),
        5555
    );

    acceptor.open(endpoint.protocol());

    acceptor.set_option(asio::socket_base::reuse_address(true));
    acceptor.bind(endpoint);
    acceptor.listen();

    std::promise<void> started;
    std::future<void> ready = started.get_future();

    serverThread = std::thread([this, &started] {
        try {
            std::cout << "Server listening on port 5555...\n";
            this->isServerRunning = true;
            started.set_value();

            acceptClient();

            io.run();

            this->isServerRunning = false;
        } catch (const std::exception& error) {
            this->isServerRunning = false;
            std::cerr << "Server error: " << error.what() << '\n';
        }
    });

    ready.wait();
}

void Server::stopServer() {

    json message = {
        {"messageType", "serverClose"}
    };
    std::string messageStr = message.dump() + "\n";
    for (auto& [_, client]: clients) {
        asio::write(client, asio::buffer(messageStr));
    }
    
    this->isServerRunning = false;

    if (this->acceptor.is_open()) {
        this->acceptor.close();
    }

    this->io.stop();

    if (serverThread.joinable()) {
        serverThread.join();
    }
}

void Server::acceptClient() {
    acceptor.async_accept(
        [this](const std::error_code& error, asio::ip::tcp::socket client) {
            if (error) {
                if (this->isServerRunning) {
                    std::cerr << "Accept Error: " << error.message() << std::endl;
                }
                return;
            }

            ClientIdentity identity = create_identity(client);
            auto [clientIt, clientInserted] = clients.emplace(
                identity,
                std::move(client)
            );
            
            if (clientInserted) {
                receiveBuffers.try_emplace(identity);
                clientsConnected++;
                this->listenToClient(identity);
            }

            acceptClient();
        }
    );
}

void Server::listenToClient(const ClientIdentity& identity) {

    auto clientIt = clients.find(identity);
    if (clientIt == clients.end()) {
        return;
    }
    auto receiveBufferIt = receiveBuffers.find(identity);
    if (receiveBufferIt == receiveBuffers.end()) {
        return;
    }
    asio::ip::tcp::socket& client = clientIt->second;
    asio::streambuf& receiveBuffer = receiveBufferIt->second; 
    
    asio::async_read_until(
        client,
        receiveBuffer,
        "\n",
        [this, identity, &receiveBuffer](const std::error_code& error, std::size_t) {
            if (error) {
                clients.erase(identity);
                receiveBuffers.erase(identity);
                clientsConnected--;
                return;
            }

            auto& buffer = receiveBuffer;
            std::istream stream(&buffer);

            std::string message;
            std::getline(stream, message);

            std::cout << "Received: " << message << std::endl;

            listenToClient(identity);
        }
    );
}

void Server::beginSendToClients(
    const fs::path& fullPath, 
    const std::vector<std::vector<BreadthFileNode>>& files
) {
    /// if our fullPath is something like "Foo/"
    /// SourceRoot will be "/Users/name/documents/Foo/"
    const fs::path sourceRoot = fs::canonical(fullPath);
    
    const auto sourcePath = [&sourceRoot](const std::string& relativePath) {
        fs::path relative(relativePath);
        if (!relative.empty() && *relative.begin() == sourceRoot.filename()) {
            relative = relative.lexically_relative(sourceRoot.filename());
        }
        return sourceRoot / relative;
    };

    /// Send Starting Flag So Client Knows We're Starting
    this->sendStartPayload();

    for (const auto& level: files) {
        for (const auto& file: level) {
            fs::path path = sourcePath(file.relativePath);

            if (file.type == NodeType::file && !fs::is_regular_file(path)) {
                throw std::runtime_error("file not found: " + path.string());
            }
            if (!file.size.has_value()) continue;
            std::uint32_t pathLength = static_cast<std::uint32_t>(file.relativePath.size());
            std::uint64_t sentBytes = 0;
            std::uint64_t totalBytes = file.size.value();
            
            ServerFile serverFile = {
                file.type,
                pathLength,
                sentBytes,
                totalBytes
            };
            sendInitialMetadata(serverFile, file);
        }
    }

    /// send the initial file info metadata done message
    this->sendInitialFileInfoMetadataDone();
    
    /// now we send the file data
    for (const auto& level: files) {
        std::unordered_map<fs::path, std::size_t> lastFileBuffer;
        std::unordered_map<fs::path, std::size_t> totalFileBuffer;
        std::unordered_map<fs::path, std::string> relativePaths;
        // constexpr size_t kChunkSize = 64 * 1024;
        constexpr size_t kChunkSize = 1024 * 1024;
        /// for a single level we store the path -> buffer
        /// first pass we populate lastFileBuffer and totalFileBuffer
        /// and we send the file data to the clients, next loop should
        /// resume from lastFileBuffer and totalFileBuffer
        for (const auto& file: level) {
            if (file.type == NodeType::folder) {
                continue;
            }
            fs::path path = sourcePath(file.relativePath);
            
            std::ifstream ifStreamFile(path, std::ios::binary);
            if (!ifStreamFile) {
                throw std::runtime_error("failed reading file: " + path.string());
            }
            relativePaths[path] = file.relativePath;

            auto it = totalFileBuffer.find(path);
            if (it == totalFileBuffer.end()) {
                /// doesnt exist so we can populate
                ifStreamFile.seekg(0, std::ios::end);
                totalFileBuffer[path] = static_cast<std::size_t>(ifStreamFile.tellg());
                ifStreamFile.seekg(0, std::ios::beg);
            }
            
            std::size_t totalSize = totalFileBuffer[path];

            /// [] is a creation, so if doesnt exist default will be 0 if doesnt exist
            std::size_t offset = lastFileBuffer[path];

            if (offset >= totalSize) {
                continue;
            }

            ifStreamFile.seekg(static_cast<std::streamoff>(offset), std::ios::beg);
            std::vector<uint8_t> buffer(kChunkSize);

            ifStreamFile.read(reinterpret_cast<char*>(buffer.data()), kChunkSize);
            std::size_t bytesRead = static_cast<std::size_t>(ifStreamFile.gcount());
            buffer.resize(bytesRead);

            lastFileBuffer[path] += bytesRead;

            /// now we send the data to the client
            this->sendFileData(
                file.relativePath, 
                offset, 
                bytesRead, 
                buffer
            );
        }

        /// keep looping while at least one file still has bytes remaining
        bool anyFilesRemaining = true;
        while (anyFilesRemaining) {
            bool anyFilesRemainingThisIteration = false;
            for (const auto& [path, totalSize]: totalFileBuffer) {
                std::size_t offset = lastFileBuffer[path];
                if (offset < totalSize) {
                    anyFilesRemainingThisIteration = true;
                } else {
                    continue;
                }
                
                std::ifstream ifStreamFile(path, std::ios::binary);
                if (!ifStreamFile) {
                    throw std::runtime_error("failed reading file: " + path.string());
                }
                
                ifStreamFile.seekg(static_cast<std::streamoff>(offset), std::ios::beg);
                std::vector<uint8_t> buffer(kChunkSize);
    
                ifStreamFile.read(reinterpret_cast<char*>(buffer.data()), kChunkSize);
                std::size_t bytesRead = static_cast<std::size_t>(ifStreamFile.gcount());
                buffer.resize(bytesRead);
    
                lastFileBuffer[path] += bytesRead;

                /// we send the data to the client
                this->sendFileData(
                    relativePaths[path], 
                    offset, 
                    bytesRead, 
                    buffer
                );
            }
            
            anyFilesRemaining = anyFilesRemainingThisIteration;
        }
    }

    // send final file info metadata done message
    sendMetadataDone();
}

/// Function sends the start payload to all the clients so they can clear any existing buffers
/// and start receiving new data
void Server::sendStartPayload() {
    json startData = {
        { "messageType", "start" }
    };
    std::string startPayload = startData.dump() + "\n";
    for (auto& [_, client]: clients) {
        asio::write(client, asio::buffer(startPayload));
    }
}

/// Function sends the initial metadata of a file to all the clients
void Server::sendInitialMetadata(ServerFile serverFile, BreadthFileNode file) {
    /// Convert to json
    json jsonData = {
        { "messageType", "fileInfo" },
        { "type", nodeTypeToString(serverFile.type) },
        { "pathLength", serverFile.pathLength },
        { "sentBytes", serverFile.sentBytes },
        { "totalBytes", serverFile.totalBytes },
        { "relativePath", file.relativePath }
    };
    std::string payload = jsonData.dump() + "\n";

    /// Send To Client
    for (auto& [_, client]: clients) {
        asio::write(client, asio::buffer(payload));
    }
}

void Server::sendInitialFileInfoMetadataDone() {
    json doneData = {
        {"messageType", "initialFileInfoMetadataDone" }
    };
    std::string donePayload = doneData.dump() + "\n";
    for (auto& [_, client]: clients) {
        asio::write(client, asio::buffer(donePayload));
    }
}

void Server::sendFileData(
    std::string relativePath,
    std::size_t offset,
    std::size_t bytesRead,
    std::vector<uint8_t> buffer
) {
    /// now we send the data to the client
    json jsonData = {
        { "messageType", "fileData" },
        { "relativePath", relativePath },
        { "offset", offset },
        { "bytesRead", bytesRead }
    };
    std::string payload = jsonData.dump() + "\n";
    for (auto& [_, client]: clients) {
        asio::write(client, asio::buffer(payload));
        asio::write(client, asio::buffer(buffer));
    }
}

void Server::sendMetadataDone() {
    json doneData = {
        {"messageType", "finalFileInfoMetadataDone" }
    };
    std::string donePayload = doneData.dump() + "\n";
    for (auto& [client, socket]: clients) {
        asio::write(socket, asio::buffer(donePayload));
    }
}
