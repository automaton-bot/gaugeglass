# GitHub macOS compile check

`.github/workflows/ios-simulator.yml` is a **manual-only**, shell-based workflow using the standard `macos-15-intel` runner with a 20-minute job timeout and read-only repository permissions. It has no third-party `uses:` Actions, Node-based automation, Apple credentials, repository secrets, signing, release publishing, or hardware access.

The job checks out the exact requested public commit, selects the preinstalled Xcode 16.4 toolchain, runs the portable core tests and app-policy checks on macOS, generates the project, and performs an unsigned generic iOS Simulator build. The final step checks for the app executable and reports its bundle identifier. Compiler/test output remains in the GitHub Actions logs; this workflow does not upload an artifact or create a sideloadable IPA.

XcodeGen is pinned to 2.44.1. The archive SHA-256 `a2e905fb68446e9bb4008cdfe2e13e3f176d0cbcca828b71770f8e53fca91b73` was obtained from the upstream release asset metadata and verified against the downloaded archive before creating the workflow. This pins the release bytes; it is not independent proof of publisher signing.

To run it, select **Actions → Unsigned iOS simulator compile → Run workflow**, or use:

```sh
gh workflow run ios-simulator.yml --repo automaton-bot/gaugeglass --ref main
```

Use the intended account's authentication. Do not put access tokens or signing material into the workflow. Standard runner/public-repository compute was selected; do not change to a paid larger runner without approval.

A successful compile establishes Apple SDK build compatibility for the selected toolchain—not simulator launch, device installation, BLE communication, verified physical units, or valve safety. The first run's actual outcome must be inspected before claiming compilation success.
