// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "AttriloopSDK",
  platforms: [.iOS(.v13), .macOS(.v10_15)],
  products: [
    .library(name: "AttriloopSDK", targets: ["AttriloopSDK"])
  ],
  targets: [
    .target(
      name: "AttriloopSDK",
      resources: [.copy("PrivacyInfo.xcprivacy")]
    ),
    .testTarget(name: "AttriloopSDKTests", dependencies: ["AttriloopSDK"]),
  ]
)
