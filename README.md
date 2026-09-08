# AgentPad13 Companion

AgentPad13 Companion is a macOS menu bar app for the [AgentPad13](https://github.com/yuz207/agentpad13) macropad. It maps Codex sessions and commands to hardware controls, and maps session state to key lighting. This pilot supports Codex.

## Requirements

- macOS 13 or later
- Swift 6.2 or later
- Codex desktop, with a `codex` executable discoverable through `PATH`, `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, or the ChatGPT app bundle in `/Applications` or `~/Applications`
- An AgentPad13 connected over USB

## Build

```sh
./scripts/build-macos-app.sh release
open .build/AgentPad13.app
```

No notarized app download is published yet.

## Setup

1. Click the AgentPad13 menu bar icon, then choose **Settings…**.
2. Open the **Hooks** status control and choose **Install Hooks**.
3. If the input status requires permission, choose **Open Input Monitoring**, allow AgentPad13, and retry the device connection.
4. In **Controls**, select a key, encoder action, or joystick direction and set its role to **Agent**, **Command**, or **Off**. Agent controls follow the selected assignment mode: **Most Recent**, **Priority**, **Pinned**, or **Custom**. Custom mode lets you choose an exact Codex session; Command controls let you choose an available command.

The companion code is available under the [MIT License](LICENSE). Bundled HIDAPI code retains its [BSD-style license](Vendor/CHIDAPI/LICENSE-bsd.txt).
