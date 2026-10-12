#!/usr/bin/env python3
"""Linux checks only: portable semantic tests, Apple-source syntax, config invariants."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess

root = Path(__file__).resolve().parent
repo = root.parent
swiftc = os.environ.get("SWIFTC") or shutil.which("swiftc")
if not swiftc:
    raise SystemExit("Set SWIFTC to a Swift 6 compiler")
build = root / ".validation"
build.mkdir(exist_ok=True)

def run(args):
    subprocess.run([str(a) for a in args], cwd=root, check=True)

run([swiftc, "-swift-version", "6", "-emit-library", "-emit-module", "-module-name", "GaugeglassCore",
     "-emit-module-path", build / "GaugeglassCore.swiftmodule", *sorted((repo / "Sources/GaugeglassCore").glob("*.swift")),
     "-o", build / "libGaugeglassCore.so"])
run([swiftc, "-swift-version", "6", "-parse-as-library", "-I", build, "-L", build, "-lGaugeglassCore",
     "-Xlinker", "-rpath", "-Xlinker", build, root / "Gaugeglass/InstrumentPolicy.swift",
     root / "Tests/PolicyChecks.swift", "-o", build / "policy-checks"])
run([build / "policy-checks"])
app_sources = sorted((root / "Gaugeglass").glob("*.swift"))
assert {source.name for source in app_sources} == {
    "InstrumentPolicy.swift", "InstrumentModel.swift", "ConnectionTransport.swift", "GaugeglassApp.swift"
}
for source in app_sources:
    run([swiftc, "-frontend", "-parse", source])
print("PASS: Swift grammar for all app sources (NOT Apple SDK typechecking)")

# Source-level scheduling regression guard, not an iOS scrolling/runtime test.
model_source = (root / "Gaugeglass/InstrumentModel.swift").read_text()
assert "Timer.scheduledTimer" not in model_source, "Default-mode timer can freeze freshness while tracking"
assert "RunLoop.main.add(foregroundTimer, forMode: .common)" in model_source, "Foreground ticker must use common run-loop modes"
print("PASS: common-mode foreground ticker source invariant (NOT iOS runtime verification)")

spec_path = root / "project.json"
assert spec_path.is_file(), "Missing XcodeGen configuration"
if spec_path.exists():
    spec = json.loads(spec_path.read_text())
    assert spec["options"]["minimumXcodeGenVersion"] == "2.44.1"
    target = spec["targets"]["Gaugeglass"]
    assert target["platform"] == "iOS" and target["type"] == "application"
    assert target["deploymentTarget"] == "16.0"
    assert spec["packages"]["GaugeglassCore"]["path"] == ".."
    assert (root / spec["packages"]["GaugeglassCore"]["path"] / "Package.swift").is_file()
    assert target["dependencies"] == [{"package": "GaugeglassCore", "product": "GaugeglassCore"}]
    assert target["sources"] == [{"path": "Gaugeglass", "excludes": ["Info.plist"]}]
    assert target["settings"]["base"]["SWIFT_VERSION"] == "6.0"
    assert target["settings"]["base"]["INFOPLIST_FILE"] == "Gaugeglass/Info.plist"
    plist = plistlib.loads((root / "Gaugeglass/Info.plist").read_bytes())
    assert plist["NSBluetoothAlwaysUsageDescription"]
    assert "UIBackgroundModes" not in plist
    assert plist["CFBundleExecutable"] == "$(EXECUTABLE_NAME)"
    assert spec["schemes"]["Gaugeglass"]["build"]["targets"] == {"Gaugeglass": "all"}
    print("PASS: JSON/plist parsing and local package, target, scheme, foreground-only config invariants")
    print("NOT RUN: XcodeGen generation, xcodebuild, Apple SDK typecheck, signing, BLE/hardware tests")
