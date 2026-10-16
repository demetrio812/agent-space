// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "HerdrHelperCore", platforms: [.macOS(.v13)], products: [.library(name: "HerdrHelperCore", targets: ["HerdrHelperCore"])], targets: [.target(name: "HerdrHelperCore", path: ".", exclude: ["Tests", "Info.plist", "build-helper", "main.swift"], sources: ["HelperCore.swift", "BridgeJob.swift", "HerdrHelperProtocol.swift", "HerdrHelperService.swift"]), .testTarget(name: "HerdrHelperCoreTests", dependencies: ["HerdrHelperCore"], path: "Tests")])
