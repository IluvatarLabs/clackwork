// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "Clackwork",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .executable(name: "Clackwork", targets: ["AgentPadV2"]),
  ],
  targets: [
    .target(
      name: "CHIDAPI",
      path: "Vendor/CHIDAPI",
      sources: ["mac/hid.c"],
      publicHeadersPath: "include",
      cSettings: [
        .headerSearchPath("include/hidapi")
      ],
      linkerSettings: [
        .linkedFramework("CoreFoundation"),
        .linkedFramework("IOKit"),
      ]
    ),
    .executableTarget(
      name: "AgentPadV2",
      dependencies: ["CHIDAPI"]
    ),
  ]
)
