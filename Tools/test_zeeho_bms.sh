#!/usr/bin/env bash
# Run the production ZEEHO output/codec with a native in-memory instrument transport.
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
zeeho_bms_dir="$(mktemp -d "${TMPDIR:-/tmp}/carwithin-zeeho-bms.XXXXXX")"
trap 'rm -rf "$zeeho_bms_dir"' EXIT
# Compile the production error type without importing the unrelated receiver configuration graph.
python3 - "$project_root/App/ReceiverConfiguration.swift" "$zeeho_bms_dir/ConfigurationError.swift" <<'PYTHON'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
start = source.index('struct ConfigurationError: LocalizedError {')
end = source.index('\n}', start) + 2
Path(sys.argv[2]).write_text('import Foundation\n' + source[start:end] + '\n')
PYTHON
"${SWIFTC:-swiftc}" -swift-version 5 \
    "$zeeho_bms_dir/ConfigurationError.swift" \
    "$project_root/Sources/TDSCarKitCore/BMSFamily.swift" \
    "$project_root/Sources/TDSCarKitCore/ANTBMSProtocol.swift" \
    "$project_root/Sources/TDSCarKitCore/ANTBMSCardConfiguration.swift" \
    "$project_root/Sources/TDSCarKitCore/Localization.swift" \
    "$project_root/Sources/TDSCarKitCore/Binary.swift" \
    "$project_root/Sources/TDSCarKitCore/VideoCodec.swift" \
    "$project_root/Sources/TDSCarKitCore/AnnexB.swift" \
    "$project_root/App/TailingDisplayProfile.swift" "$project_root/App/TailingProtocol.swift" \
    "$project_root/App/InstrumentVideoCanvas.swift" "$project_root/App/ZeehoOutput.swift" \
    "$project_root/App/NinebotProtocol.swift" "$project_root/App/NinebotH264Encoder.swift" \
    "$project_root/App/TailingH264Decoder.swift" "$project_root/Tools/ZeehoBMSOutputSmoke.swift" \
    -framework AVFoundation -framework VideoToolbox -framework CoreImage -framework CoreVideo \
    -o "$zeeho_bms_dir/zeeho-bms-tests"
"$zeeho_bms_dir/zeeho-bms-tests"
