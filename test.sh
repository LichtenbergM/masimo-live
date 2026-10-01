#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build
xcrun swiftc -module-cache-path .build/module-cache -swift-version 5 -parse-as-library Sources/Protocol.swift Tests/ProtocolTests.swift -o .build/protocol-tests
.build/protocol-tests
xcrun swiftc -module-cache-path .build/module-cache -swift-version 5 -parse-as-library Sources/ScreenReading.swift Tests/ScreenReadingTests.swift -o .build/screen-tests
.build/screen-tests
xcrun swiftc -module-cache-path .build/module-cache -swift-version 5 -parse-as-library Sources/Protocol.swift Sources/LiveExport.swift Tests/LiveExportTests.swift -o .build/live-export-tests
.build/live-export-tests
PYTHONDONTWRITEBYTECODE=1 python3 Tests/LiveClientTests.py
