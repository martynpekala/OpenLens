import ProjectDescription

let project = Project(
    name: "OpenLensRemote",
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
            name: "OpenLensRemote",
            destinations: .macOS,
            product: .app,
            bundleId: "dev.openlens.remote",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "OpenLens Remote",
                "LSApplicationCategoryType": "public.app-category.developer-tools",
                "LSUIElement": true,
            ]),
            sources: [
                "RemoteSources/**",
                "../../OpenLensRemoteCore/**",
            ],
            resources: ["Resources/**"],
            settings: .settings(
                base: [
                    "PRODUCT_NAME": "OpenLensRemote",
                ]
            )
        ),
        .target(
            name: "OpenLensRemoteTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "dev.openlens.remote.tests",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .default,
            sources: ["RemoteTests/**"],
            dependencies: [
                .target(name: "OpenLensRemote"),
            ]
        ),
    ]
)
