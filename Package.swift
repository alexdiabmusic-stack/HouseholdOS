// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "HouseholdCore",
    platforms: [.iOS("18.0"), .macOS(.v14)],
    products: [.library(name:"HouseholdCore",targets:["HouseholdCore"])],
    targets: [
        .target(name:"HouseholdCore",path:"HouseholdOS/Core"),
        .testTarget(name:"HouseholdCoreTests",dependencies:["HouseholdCore"],path:"Tests/HouseholdCoreTests")
    ]
)
