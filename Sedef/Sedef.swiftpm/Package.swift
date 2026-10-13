// swift-tools-version: 5.9

// Swift Playgrounds (iPad) app package. Also opens in Xcode on a Mac.

import PackageDescription
import AppleProductTypes

let package = Package(
    name: "Sedef",
    platforms: [
        .iOS("17.0")
    ],
    products: [
        .iOSApplication(
            name: "Sedef",
            targets: ["AppModule"],
            bundleIdentifier: "app.sedef.browser",
            displayVersion: "1.0",
            bundleVersion: "1",
            appIcon: .placeholder(icon: .gamepad),
            accentColor: .presetColor(.red),
            supportedDeviceFamilies: [
                .pad,
                .phone
            ],
            supportedInterfaceOrientations: [
                .landscapeRight,
                .landscapeLeft,
                .portrait,
                .portraitUpsideDown(.when(deviceFamilies: [.pad]))
            ],
            appCategory: .utilities,
            additionalInfoPlistContentFilePath: "Info-Extra.plist"
        )
    ],
    targets: [
        .executableTarget(
            name: "AppModule",
            path: ".",
            exclude: ["Info-Extra.plist"]
        )
    ]
)
