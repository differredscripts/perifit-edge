#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ "${2:-}" = "--finder" ]; then
    swift build -c release --scratch-path .build/finder -Xswiftc -DFINDER_PROTOTYPE
    perifit_bin_dir=$(swift build -c release --scratch-path .build/finder --show-bin-path)
else
    swift build -c release
    perifit_bin_dir=$(swift build -c release --show-bin-path)
fi
perifit_app=${1:-"dist/Perifit Edge.app"}
mkdir -p "$perifit_app/Contents/MacOS" "$perifit_app/Contents/Resources"
cp "$perifit_bin_dir/PerifitEdge" "$perifit_app/Contents/MacOS/PerifitEdge"
cp Resources/Info.plist "$perifit_app/Contents/Info.plist"
cp Vendor/EdgeOMatic/LICENSE "$perifit_app/Contents/Resources/Edge-o-Matic-LICENSE.txt"
cp PROVENANCE.md "$perifit_app/Contents/Resources/PROVENANCE.md"
cp USB_PROTOCOL.md ARDUINO_HANDOFF.md "$perifit_app/Contents/Resources/"
perifit_identifier=local.perifit-edge.app
if [ "${2:-}" = "--finder" ]; then
    perifit_identifier=local.perifit-edge.finder
    python3 - "$perifit_app/Contents/Info.plist" <<'PY'
import plistlib, sys
from pathlib import Path
path = Path(sys.argv[1])
info = plistlib.loads(path.read_bytes())
info.update(CFBundleName='Perifit Edge Finder', CFBundleDisplayName='Perifit Edge Finder',
            CFBundleIdentifier='local.perifit-edge.finder', CFBundleShortVersionString='1.0.0', CFBundleVersion='100')
path.write_bytes(plistlib.dumps(info))
PY
fi
codesign --force --sign - --identifier "$perifit_identifier" "$perifit_app"
codesign --verify --strict "$perifit_app"
echo "Built $perifit_app"
