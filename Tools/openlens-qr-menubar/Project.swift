import ProjectDescription

let project = Project(
    name: "OpenLensQRMenubar",
    options: .options(
        automaticSchemesOptions: .enabled()
    ),
    settings: .settings(
        base: [
            "SWIFT_VERSION": "5.0",
            "CODE_SIGNING_ALLOWED": "NO",
            "CODE_SIGNING_REQUIRED": "NO",
        ]
    ),
    targets: [
        .target(
            name: "OpenLensQRMenubar",
            destinations: .macOS,
            product: .app,
            bundleId: "dev.openlens.openlens-qr-menubar",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "OpenLens QR",
                "LSUIElement": true,
                "OpenLensQRPackagePath": "$(SRCROOT)/../openlens-qr",
            ]),
            sources: ["Sources/**"],
            settings: .settings(
                base: [
                    "PRODUCT_NAME": "OpenLensQRMenubar",
                ]
            )
        ),
    ]
)
