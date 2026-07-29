// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MailSurgeon",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MailSurgeon", targets: ["MailSurgeon"])
    ],
    targets: [
        .executableTarget(
            name: "MailSurgeon",
            path: "Sources/MailSurgeon"
        ),
        .testTarget(
            name: "MailSurgeonTests",
            dependencies: ["MailSurgeon"]
        )
    ]
)
