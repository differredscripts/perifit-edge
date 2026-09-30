#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift build -c release
perifit_bin_dir=$(swift build -c release --show-bin-path)
perifit_probe_dir=$(mktemp -d /tmp/perifit-mac-probe.XXXXXX)
trap 'rm -rf "$perifit_probe_dir"' EXIT
xcrun swiftc -parse-as-library -swift-version 5 \
  -I "$perifit_bin_dir/Modules" -I "$perifit_bin_dir/EOMCore.build" \
  Sources/PerifitApp/ArduinoUSB.swift Sources/PerifitApp/USBSerialWorker.swift Sources/PerifitApp/USBDebugLog.swift Firmware/MacProbe.swift \
  "$perifit_bin_dir"/PerifitCore.build/*.o "$perifit_bin_dir"/EOMCore.build/*.o \
  -o "$perifit_probe_dir/check"
"$perifit_probe_dir/check" "$@"
