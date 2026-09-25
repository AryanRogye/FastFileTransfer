#include "Server.h"
#include <FileInfo.h>
#include <FolderInfo.h>
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

Server::Server(): acceptor(
    io,
    asio::ip::tcp::endpoint(asio::ip::tcp::v4(), 5555)
) {}

Server::~Server() {
    this->stopServer();
}

void Server::startServer() {
    if(thread.joinable()) {
        return;
    }

    std::promise<void> started;
    std::future<void> ready = started.get_future();

    thread = std::thread([this, &started] {
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
    this->isServerRunning = false;

    if (this->acceptor.is_open()) {
        this->acceptor.close();
    }

    this->io.stop();

    if (thread.joinable()) {
        thread.join();
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
            auto it = clients.find(identity);
            if (it == clients.end()) {
                this->clients.emplace(identity, std::move(client));
                this->clientsConnected++;
            }

            acceptClient();
        }
    );
}

struct ServerFile {
    NodeType type;
    std::uint32_t pathLength;
    std::uint64_t sentBytes;
    std::uint64_t totalBytes;
};

void Server::beginSendToClients(
    const fs::path& fullPath, 
    const std::vector<std::vector<BreadthFileNode>>& files
) {

    /// Send Starting Flag So Client Knows We're Starting
    json startData = {
        { "messageType", "start" }
    };
    std::string startPayload = startData.dump() + "\n";
    for (auto& [_, client]: clients) {
        asio::write(client, asio::buffer(startPayload));
    }

    std::vector<std::vector<ServerFile>> serverFiles;
    for (const auto& level: files) {
        std::vector<ServerFile> serverFileLevel;
        for (const auto& file: level) {
            fs::path path = fullPath / fs::path(file.relativePath);
            std::uint32_t pathLength = static_cast<std::uint32_t>(file.relativePath.size());
            std::uint64_t sentBytes = 0;
            std::uint64_t totalBytes = FileInfo::size(path);
            ServerFile serverFile = {
                file.type,
                pathLength,
                sentBytes,
                totalBytes
            };
            serverFileLevel.push_back(serverFile);

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
        serverFiles.push_back(serverFileLevel);
    }

    json doneData = {
        {"messageType", "initialFileInfoMetadataDone" }
    };

    std::string donePayload = doneData.dump() + "\n";
    for (auto& [_, client]: clients) {
        asio::write(client, asio::buffer(donePayload));
    }

    json startingDataLoad = {
        {"messageType", "startingDataLoad"}
    };
    std::string startingDataLoadPayload = startingDataLoad.dump() + "\n";
    for (auto& [_, client]: clients) {
        asio::write(client, asio::buffer(startingDataLoadPayload));
    }

    /// now we send the file data
    for (const auto& level: files) {
        std::unordered_map<fs::path, std::size_t> lastFileBuffer;
        std::unordered_map<fs::path, std::size_t> totalFileBuffer;
        std::unordered_map<fs::path, std::string> relativePaths;
        constexpr size_t kChunkSize = 10;
        /// for a single level we store the path -> buffer
        /// first pass we populate lastFileBuffer and totalFileBuffer
        /// and we send the file data to the clients, next loop should
        /// resume from lastFileBuffer and totalFileBuffer
        for (const auto& file: level) {
            if (file.type == NodeType::folder) {
                continue;
            }
            fs::path path = file.relativePath;
            
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
            json jsonData = {
                { "messageType", "fileData" },
                { "relativePath", file.relativePath },
                { "offset", offset },
                { "bytesRead", bytesRead }
            };
            std::string payload = jsonData.dump() + "\n";
            for (auto& [_, client]: clients) {
                asio::write(client, asio::buffer(payload));
                asio::write(client, asio::buffer(buffer));
            }
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

                json jsonData = {
                    { "messageType", "fileData" },
                    { "relativePath", relativePaths[path] },
                    { "offset", offset },
                    { "bytesRead", bytesRead }
                };
                std::string payload = jsonData.dump() + "\n";
                for (auto& [_, client]: clients) {
                    asio::write(client, asio::buffer(payload));
                    asio::write(client, asio::buffer(buffer));
                }
            }
            
            anyFilesRemaining = anyFilesRemainingThisIteration;
        }
    }

    // send final file info metadata done message
    doneData = {
        {"messageType", "finalFileInfoMetadataDone" }
    };
    donePayload = doneData.dump() + "\n";
    for (auto& [client, socket]: clients) {
        asio::write(socket, asio::buffer(donePayload));
    }

    std::cout << "Sent File Info" << std::endl;
}
