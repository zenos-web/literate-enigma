#!/usr/bin/env bash
# Real Core Image / JPEG composition on native macOS; no simulator.
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
canvas_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/carwithin-ninebot-canvas.XXXXXX")"
trap 'rm -rf "$canvas_test_dir"' EXIT
"${SWIFTC:-swiftc}" -swift-version 5 \
    "$project_root/Sources/TDSCarKitCore/BMSFamily.swift" \
    "$project_root/Sources/TDSCarKitCore/ANTBMSProtocol.swift" \
    "$project_root/Sources/TDSCarKitCore/ANTBMSCardConfiguration.swift" \
    "$project_root/App/InstrumentVideoCanvas.swift" "$project_root/Tools/NinebotCanvasSmoke.swift" \
    "$project_root/Sources/TDSCarKitCore/Binary.swift" \
    "$project_root/Sources/TDSCarKitCore/VideoCodec.swift" \
    "$project_root/Sources/TDSCarKitCore/AnnexB.swift" \
    "$project_root/Sources/TDSCarKitCore/Localization.swift" \
    "$project_root/App/NinebotProtocol.swift" \
    "$project_root/App/NinebotH264Encoder.swift" "$project_root/App/TailingH264Decoder.swift" \
    -framework AVFoundation -framework VideoToolbox -framework CoreImage -framework CoreVideo -framework ImageIO -o "$canvas_test_dir/canvas-tests"
"$canvas_test_dir/canvas-tests"
