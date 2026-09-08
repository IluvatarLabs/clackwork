# CHIDAPI provenance

This target vendors the unmodified macOS backend and public headers from
libusb/hidapi `hidapi-0.15.0`, commit
`d6b2a974608dec3b76fb1e36c189f22b9cf3650c`:

- `mac/hid.c`
- `include/hidapi/hidapi.h`
- `include/hidapi/hidapi_darwin.h`

AgentPad13 uses HIDAPI under the BSD-style license in `LICENSE-bsd.txt`. No
other HIDAPI backend, wrapper, binary, or build system is included.
