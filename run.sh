#!/bin/bash
set -e

cmake --build build
./build/FastFileTransfer FastFileReceiver
