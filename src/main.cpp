#include <FolderInfo.h>
#include <iostream>
#include <filesystem>
#include "Server.h"

namespace fs = std::filesystem;

int main(int argc, const char* argv[]) {

    std::string userPath;
    if (argc == 2) {
        userPath = argv[1];
    } else {
      std::cout << "Please Type Path Or Use .. To Use CWD" << std::endl;
      std::cout << "> ";
      std::cin >> userPath;
      std::cout << std::endl;
    }

    fs::path path = userPath;
    if (!fs::is_directory(path)) {
        std::cout << "Not A Directory" << std::endl;
        return 0;
    }
    FolderInfo info(path);
    info.generate();

    Server server;

    std::string input;
    std::cout << "Start Server? y/n > ";
    std::cin >> input;
    
    if (input != "y") return 0;

    server.startServer();

    while (server.isServerRunning) {
        std::string loopInput;
        std::cout << "1. List Number Of Clients" << std::endl;
        std::cout << "2. Stop Server" << std::endl;
        std::cout << "3. Send Folder To Clients " << std::endl;
        std::cout << "> ";
        std::cin >> loopInput;
        std::cout << std::endl;

        if (loopInput == "1") {
            std::cout << server.clientsConnected << " Client(s) connected" << std::endl;
            std::cout << std::endl;
        }
        else if (loopInput == "2") {
            std::cout << "Stopping Server" << std::endl;
            server.stopServer();
        }
        else if (loopInput == "3") {
            std::cout << "Sending Folder To Clients" << std::endl;
            server.beginSendToClients(
                path, info.getLevels()
            );
        }
    }

    return 0;
}
