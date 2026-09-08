# Clackwork

Physical controls for coding agents. Clackwork is a macOS menu bar app that maps Codex sessions and commands to the [AgentPad13](https://github.com/yuz207/agentpad13) macropad, then reflects session state through its key lighting. Current support is Codex with AgentPad13; other keyboards and macropads are not supported yet.

## Prerequisites

- macOS 13 or later
- Swift 6.2 or later
- Codex desktop, with a `codex` executable discoverable through `PATH`, `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, or the ChatGPT app bundle in `/Applications` or `~/Applications`
- An AgentPad13 connected over USB

## Build

```sh
./scripts/build-macos-app.sh release
open .build/Clackwork.app
```

## Setup

1. Click the Clackwork menu bar icon, then choose **Settings…**.
2. Open the **Hooks** status control and choose **Install Hooks**.
3. If the input status requires permission, choose **Open Input Monitoring**, allow Clackwork, and retry the device connection.
4. In **Controls**, select a key, encoder action, or joystick direction and set its role to **Agent**, **Command**, or **Off**. Agent controls follow the selected assignment mode: **Most Recent**, **Priority**, **Pinned**, or **Custom**. Custom mode lets you choose an exact Codex session; Command controls let you choose an available command.

Clackwork is available under the [MIT License](LICENSE). Bundled HIDAPI code retains its [BSD-style license](Vendor/CHIDAPI/LICENSE-bsd.txt).
