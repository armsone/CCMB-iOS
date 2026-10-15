#!/bin/sh
# Builds and runs the standalone fixture harness against the real
# UsageSnapshot / NASClient / NASCacheCodec sources. Synthetic fixtures only.
set -e
cd "$(dirname "$0")/../.."
swiftc -swift-version 5 \
    CCMB/Models/NASHostStatus.swift \
    CCMB/Models/UsageSnapshot.swift \
    CCMB/Store/NASClient.swift \
    CCMB/Store/NASCacheCodec.swift \
    scripts/parser_verify/main.swift \
    -o /tmp/ccmb-parser-verify
/tmp/ccmb-parser-verify
