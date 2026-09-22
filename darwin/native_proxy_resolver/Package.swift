// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "native_proxy_resolver",
  platforms: [
    .iOS("13.0"),
    .macOS("10.15"),
  ],
  products: [
    .library(name: "native-proxy-resolver", targets: ["native_proxy_resolver"])
  ],
  dependencies: [],
  targets: [
    .target(
      name: "native_proxy_resolver",
      dependencies: [],
      resources: [
        .process("Resources")
      ],
      linkerSettings: [
        .linkedFramework("CFNetwork"),
        .linkedFramework("Network"),
        .linkedFramework("SystemConfiguration", .when(platforms: [.macOS])),
      ]
    )
  ]
)
