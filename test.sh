#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
/usr/bin/swiftc -swift-version 5 -D POTETO_TEST -parse-as-library Sources/Core.swift Sources/Activation.swift Tests/ActivationTests.swift -framework Security -framework LocalAuthentication -o build/poteto-activation-tests
build/poteto-activation-tests
/usr/bin/swiftc -swift-version 5 Sources/Core.swift Tests/main.swift -framework Security -framework LocalAuthentication -o build/poteto-tests
build/poteto-tests
/usr/bin/swiftc -swift-version 5 -parse-as-library Sources/Core.swift Tests/ProjectRetentionTests.swift -framework Security -framework LocalAuthentication -o build/poteto-project-retention-tests
build/poteto-project-retention-tests
/usr/bin/swiftc -swift-version 5 -D POTETO_TEST -parse-as-library Sources/Core.swift Sources/Activation.swift Sources/Panel.swift Sources/PotetoApp.swift Tests/LoginStartTests.swift -framework AppKit -framework SwiftUI -framework Security -framework LocalAuthentication -o build/poteto-login-start-tests
build/poteto-login-start-tests
/usr/bin/swiftc -swift-version 5 -D POTETO_TEST -parse-as-library Sources/Core.swift Sources/Activation.swift Sources/Panel.swift Sources/PotetoApp.swift Tests/MonitorTests.swift -framework AppKit -framework SwiftUI -framework Security -framework LocalAuthentication -o build/poteto-monitor-tests
build/poteto-monitor-tests
/usr/bin/swiftc -swift-version 5 -D POTETO_TEST -parse-as-library Sources/Core.swift Sources/Activation.swift Sources/Panel.swift Sources/PotetoApp.swift Tests/PanelInteractionTests.swift -framework AppKit -framework SwiftUI -framework Security -framework LocalAuthentication -o build/poteto-panel-interaction-tests
build/poteto-panel-interaction-tests
/usr/bin/swiftc -swift-version 5 -D POTETO_TEST -parse-as-library Sources/Core.swift Sources/Activation.swift Sources/Panel.swift Sources/PotetoApp.swift Tests/PresentationTests.swift -framework AppKit -framework SwiftUI -framework Security -framework LocalAuthentication -o build/poteto-presentation-tests
build/poteto-presentation-tests
/usr/bin/swiftc -swift-version 5 -D POTETO_TEST -parse-as-library Sources/Core.swift Sources/Activation.swift Sources/Panel.swift Sources/PotetoApp.swift Tests/AppLifecycleSmoke.swift -framework AppKit -framework SwiftUI -framework Security -framework LocalAuthentication -o build/poteto-lifecycle-smoke
python3 - <<'PY'
import json, pathlib, subprocess, tempfile
with tempfile.TemporaryDirectory(prefix="poteto-lifecycle-") as home:
    subprocess.run(["build/poteto-lifecycle-smoke", home], check=True, timeout=10)
    status = json.loads((pathlib.Path(home) / "status.json").read_text())
    assert status["accounts"] == [] and not status["refreshing"]
print("poteto: AppKit graceful shutdown check passed")
PY
/usr/bin/swiftc -swift-version 5 -D POTETO_TEST -parse-as-library Sources/Core.swift Sources/Activation.swift Sources/Panel.swift Sources/PotetoApp.swift Tests/PanelSnapshot.swift -framework AppKit -framework SwiftUI -framework Security -framework LocalAuthentication -o build/poteto-panel-snapshot
build/poteto-panel-snapshot build/panel-preview.png
build/poteto-panel-snapshot build/panel-settings-preview.png --settings
build/poteto-panel-snapshot build/panel-details-preview.png --details
if [ "${1:-}" = --motion ]; then
  /usr/bin/swiftc -swift-version 5 -D POTETO_TEST -parse-as-library Sources/Core.swift Sources/Activation.swift Sources/Panel.swift Sources/PotetoApp.swift Tests/PanelMotionSmoke.swift -framework AppKit -framework SwiftUI -framework Security -framework LocalAuthentication -o build/poteto-panel-motion-smoke
  build/poteto-panel-motion-smoke
fi
