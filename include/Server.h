#ifndef SERVER_H
#define SERVER_H

#include <FolderInfo.h>
#include <atomic>
#include <thread>
#include <asio.hpp>

struct ClientIdentity {
    std::string ip;
    unsigned short port;

    bool operator==(const ClientIdentity& other) const {
        return ip == other.ip && port == other.port;
    }
};
struct ClientIdentityHash {
    std::size_t operator()(const ClientIdentity& identity) const {
        std::size_t ipHash =
            std::hash<std::string>{}(identity.ip);

        std::size_t portHash =
            std::hash<unsigned short>{}(identity.port);

        return ipHash ^ (portHash << 1);
    }
};

class Server {
public:
    std::atomic<bool> isServerRunning = false;
    std::atomic<int> clientsConnected = 0;

    void startServer();
    void stopServer();
    void beginSendToClients(
        const fs::path& fullPath, const std::vector<std::vector<BreadthFileNode>>& files
    );

    Server();
    ~Server();
private:
    asio::io_context io;
    asio::ip::tcp::acceptor acceptor;
    std::unordered_map<ClientIdentity, asio::ip::tcp::socket, ClientIdentityHash> clients;

    std::thread thread;


    void acceptClient();
};

#endif // SERVER_H
