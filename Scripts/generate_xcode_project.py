#!/usr/bin/env python3
"""Generates XcodeSwitcher.xcodeproj/project.pbxproj.

The project file is authored as an XML plist rather than the legacy OpenStep
format so that it can be generated, diffed and reviewed as ordinary text.
Xcode reads both formats; see docs/superpowers/plans/ for the migration notes.

用法：
    python3 Scripts/generate_xcode_project.py

生成后可用 `xcodebuild -list -project XcodeSwitcher.xcodeproj` 校验。
"""

from __future__ import annotations

import hashlib
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
PROJECT_DIR = ROOT / "XcodeSwitcher.xcodeproj"

PROJECT_NAME = "XcodeSwitcher"
# Target names deliberately contain no spaces: build paths derived from them are
# used in space-separated setting lists such as SWIFT_INCLUDE_PATHS, where a
# space would silently split the path. The product keeps its user-facing name.
APP_TARGET = "XcodeSwitcher"
APP_SCHEME = "Xcode Switcher"
APP_PRODUCT_NAME = "Xcode Switcher"
APP_PRODUCT = APP_PRODUCT_NAME + ".app"
# The CLI target name must differ from the app target by more than letter case:
# macOS volumes are case-insensitive, so "XcodeSwitcher.build" and
# "xcodeswitcher.build" would be the same intermediates directory and the two
# targets would clobber each other's objects and .swiftmodule files.
CLI_TARGET = "xcodeswitcher-cli"
CLI_SCHEME = "xcodeswitcher"
CLI_PRODUCT = "xcodeswitcher"

BUNDLE_IDENTIFIER = "com.yostar.xcodeswitcher"
DEPLOYMENT_TARGET = "13.0"
MARKETING_VERSION = "1.3.0"
BUILD_NUMBER = "1"
SWIFT_VERSION = "5.0"
SPARKLE_VERSION = "2.9.6"
LOCALIZABLE_CATALOG = "Localizable.xcstrings"
SPARKLE_REPOSITORY = "https://github.com/sparkle-project/Sparkle"

def swift_sources(directory: str) -> list[str]:
    """Every .swift file in a directory, so the project cannot silently miss a
    newly added source file. Sources/ is validated against the CLI subset."""
    names = sorted(path.name for path in (ROOT / directory).glob("*.swift"))
    if not names:
        raise SystemExit(f"错误：{directory} 下没有找到任何 .swift 文件")
    return names


# Sources compiled into the app target (discovered from Sources/).
APP_SOURCES = swift_sources("Sources")

# Sources the CLI target shares with the app. Xcode lets one file belong to
# several targets, so the CLI reuses these files directly instead of needing a
# separate framework target with its own access-level annotations.
CLI_SHARED_SOURCES = [
    "CLIModels.swift",
    "EnvironmentDoctor.swift",
    "Models.swift",
    "ProjectEnvironment.swift",
    "ProjectMatching.swift",
    "Services.swift",
]

CLI_OWN_SOURCES = ["CLIEntryPoint.swift"]

TEST_TARGET = "XcodeSwitcherTests"
TEST_PRODUCT = "XcodeSwitcherTests.xctest"

TEST_SOURCES = swift_sources("Tests")

_missing_for_cli = sorted(set(CLI_SHARED_SOURCES) - set(APP_SOURCES))
if _missing_for_cli:
    raise SystemExit(f"错误：CLI 共享源文件不在 Sources/ 中：{_missing_for_cli}")


def oid(*parts: str) -> str:
    """Deterministic 24 hex character object identifier."""
    digest = hashlib.sha1("|".join(parts).encode("utf-8")).hexdigest()
    return digest[:24].upper()


def escape(value: str) -> str:
    return (
        value.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
    )


def emit(value, out: list[str], indent: int = 0) -> None:
    pad = "\t" * indent
    if isinstance(value, dict):
        out.append(f"{pad}<dict>")
        for key, item in value.items():
            out.append(f"{pad}\t<key>{escape(str(key))}</key>")
            emit(item, out, indent + 1)
        out.append(f"{pad}</dict>")
    elif isinstance(value, list):
        out.append(f"{pad}<array>")
        for item in value:
            emit(item, out, indent + 1)
        out.append(f"{pad}</array>")
    else:
        out.append(f"{pad}<string>{escape(str(value))}</string>")


MAX_BUILD_ACTION_MASK = "2147483647"


def build_objects() -> tuple[dict, str]:
    objects: dict[str, dict] = {}

    def add(identifier: str, body: dict) -> str:
        objects[identifier] = body
        return identifier

    # ---------------------------------------------------------------- groups
    sources_group = oid("group", "Sources")
    cli_sources_group = oid("group", "SourcesCLI")
    resources_group = oid("group", "Resources")
    scripts_group = oid("group", "Scripts")
    tests_group = oid("group", "Tests")
    products_group = oid("group", "Products")
    main_group = oid("group", "main")

    # ------------------------------------------------------- file references
    source_refs: dict[str, str] = {}
    for name in APP_SOURCES:
        source_refs[name] = add(
            oid("file", "Sources", name),
            {
                "isa": "PBXFileReference",
                "lastKnownFileType": "sourcecode.swift",
                "path": name,
                "sourceTree": "<group>",
            },
        )

    cli_main_ref = add(
        oid("file", "SourcesCLI", "CLIEntryPoint.swift"),
        {
            "isa": "PBXFileReference",
            "lastKnownFileType": "sourcecode.swift",
            "path": "CLIEntryPoint.swift",
            "sourceTree": "<group>",
        },
    )

    info_plist_ref = add(
        oid("file", "Resources", "Info.plist"),
        {
            "isa": "PBXFileReference",
            "lastKnownFileType": "text.plist.xml",
            "path": "Info.plist",
            "sourceTree": "<group>",
        },
    )
    entitlements_ref = add(
        oid("file", "Resources", "Debug.entitlements"),
        {
            "isa": "PBXFileReference",
            "lastKnownFileType": "text.plist.entitlements",
            "path": "Debug.entitlements",
            "sourceTree": "<group>",
        },
    )
    app_icon_ref = add(
        oid("file", "Resources", "AppIcon.svg"),
        {
            "isa": "PBXFileReference",
            "lastKnownFileType": "text.xml",
            "path": "AppIcon.svg",
            "sourceTree": "<group>",
        },
    )
    menu_icon_ref = add(
        oid("file", "Resources", "MenuBarIcon.svg"),
        {
            "isa": "PBXFileReference",
            "lastKnownFileType": "text.xml",
            "path": "MenuBarIcon.svg",
            "sourceTree": "<group>",
        },
    )
    catalog_ref = add(
        oid("file", "Resources", LOCALIZABLE_CATALOG),
        {
            "isa": "PBXFileReference",
            "lastKnownFileType": "text.json.xcstrings",
            "path": LOCALIZABLE_CATALOG,
            "sourceTree": "<group>",
        },
    )
    build_icons_ref = add(
        oid("file", "Scripts", "build_icons.sh"),
        {
            "isa": "PBXFileReference",
            "lastKnownFileType": "text.script.sh",
            "path": "build_icons.sh",
            "sourceTree": "<group>",
        },
    )

    test_source_refs: dict[str, str] = {}
    for name in TEST_SOURCES:
        test_source_refs[name] = add(
            oid("file", "Tests", name),
            {
                "isa": "PBXFileReference",
                "lastKnownFileType": "sourcecode.swift",
                "path": name,
                "sourceTree": "<group>",
            },
        )
    tests_product_ref = add(
        oid("file", "product", TEST_PRODUCT),
        {
            "isa": "PBXFileReference",
            "explicitFileType": "wrapper.cfbundle",
            "includeInIndex": "0",
            "path": TEST_PRODUCT,
            "sourceTree": "BUILT_PRODUCTS_DIR",
        },
    )
    app_product_ref = add(
        oid("file", "product", APP_PRODUCT),
        {
            "isa": "PBXFileReference",
            "explicitFileType": "wrapper.application",
            "includeInIndex": "0",
            "path": APP_PRODUCT,
            "sourceTree": "BUILT_PRODUCTS_DIR",
        },
    )
    cli_product_ref = add(
        oid("file", "product", CLI_PRODUCT),
        {
            "isa": "PBXFileReference",
            "explicitFileType": "compiled.mach-o.executable",
            "includeInIndex": "0",
            "path": CLI_PRODUCT,
            "sourceTree": "BUILT_PRODUCTS_DIR",
        },
    )

    # ------------------------------------------------------------ SPM package
    sparkle_reference = add(
        oid("package", "Sparkle"),
        {
            "isa": "XCRemoteSwiftPackageReference",
            "repositoryURL": SPARKLE_REPOSITORY,
            "requirement": {
                "kind": "exactVersion",
                "version": SPARKLE_VERSION,
            },
        },
    )
    sparkle_product = add(
        oid("packageProduct", "Sparkle", APP_TARGET),
        {
            "isa": "XCSwiftPackageProductDependency",
            "package": sparkle_reference,
            "productName": "Sparkle",
        },
    )

    # ------------------------------------------- embed the CLI in the bundle
    # The shipped app carries the CLI at Contents/MacOS/xcodeswitcher; the
    # scheme in build_app.sh copies it there, so the Xcode target must too.
    cli_copy_phase = oid("phase", APP_TARGET, "copy-cli")
    cli_copy_build_file = add(
        oid("buildFile", APP_TARGET, CLI_PRODUCT),
        {
            "isa": "PBXBuildFile",
            "fileRef": cli_product_ref,
            "settings": {"ATTRIBUTES": ["CodeSignOnCopy"]},
        },
    )
    add(
        cli_copy_phase,
        {
            "isa": "PBXCopyFilesBuildPhase",
            "buildActionMask": MAX_BUILD_ACTION_MASK,
            "dstPath": "",
            "dstSubfolderSpec": "6",
            "files": [cli_copy_build_file],
            "name": "Embed CLI",
            "runOnlyForDeploymentPostprocessing": "0",
        },
    )
    cli_container_proxy = add(
        oid("containerProxy", CLI_TARGET),
        {
            "isa": "PBXContainerItemProxy",
            "containerPortal": oid("project"),
            "proxyType": "1",
            "remoteGlobalIDString": oid("target", CLI_TARGET),
            "remoteInfo": CLI_TARGET,
        },
    )
    cli_dependency = add(
        oid("targetDependency", CLI_TARGET),
        {
            "isa": "PBXTargetDependency",
            "target": oid("target", CLI_TARGET),
            "targetProxy": cli_container_proxy,
        },
    )
    app_container_proxy = add(
        oid("containerProxy", APP_TARGET),
        {
            "isa": "PBXContainerItemProxy",
            "containerPortal": oid("project"),
            "proxyType": "1",
            "remoteGlobalIDString": oid("target", APP_TARGET),
            "remoteInfo": APP_TARGET,
        },
    )
    app_dependency = add(
        oid("targetDependency", APP_TARGET),
        {
            "isa": "PBXTargetDependency",
            "target": oid("target", APP_TARGET),
            "targetProxy": app_container_proxy,
        },
    )

    # ---------------------------------------------------------- build phases
    app_sources_phase = oid("phase", APP_TARGET, "sources")
    app_frameworks_phase = oid("phase", APP_TARGET, "frameworks")
    app_resources_phase = oid("phase", APP_TARGET, "resources")
    app_scripts_phase = oid("phase", APP_TARGET, "scripts")
    tests_sources_phase = oid("phase", TEST_TARGET, "sources")
    tests_frameworks_phase = oid("phase", TEST_TARGET, "frameworks")
    tests_resources_phase = oid("phase", TEST_TARGET, "resources")
    cli_sources_phase = oid("phase", CLI_TARGET, "sources")
    cli_frameworks_phase = oid("phase", CLI_TARGET, "frameworks")

    app_source_build_files = []
    for name in APP_SOURCES:
        app_source_build_files.append(
            add(
                oid("buildFile", APP_TARGET, name),
                {"isa": "PBXBuildFile", "fileRef": source_refs[name]},
            )
        )

    cli_source_build_files = []
    for name in CLI_SHARED_SOURCES:
        cli_source_build_files.append(
            add(
                oid("buildFile", CLI_TARGET, name),
                {"isa": "PBXBuildFile", "fileRef": source_refs[name]},
            )
        )
    for name in CLI_OWN_SOURCES:
        cli_source_build_files.append(
            add(
                oid("buildFile", CLI_TARGET, name),
                {"isa": "PBXBuildFile", "fileRef": cli_main_ref},
            )
        )

    test_source_build_files = []
    for name in TEST_SOURCES:
        test_source_build_files.append(
            add(
                oid("buildFile", TEST_TARGET, name),
                {"isa": "PBXBuildFile", "fileRef": test_source_refs[name]},
            )
        )

    catalog_build_file = add(
        oid("buildFile", APP_TARGET, LOCALIZABLE_CATALOG),
        {"isa": "PBXBuildFile", "fileRef": catalog_ref},
    )

    sparkle_build_file = add(
        oid("buildFile", APP_TARGET, "Sparkle"),
        {
            "isa": "PBXBuildFile",
            "productRef": sparkle_product,
        },
    )

    add(
        app_sources_phase,
        {
            "isa": "PBXSourcesBuildPhase",
            "buildActionMask": MAX_BUILD_ACTION_MASK,
            "files": app_source_build_files,
            "runOnlyForDeploymentPostprocessing": "0",
        },
    )
    add(
        app_frameworks_phase,
        {
            "isa": "PBXFrameworksBuildPhase",
            "buildActionMask": MAX_BUILD_ACTION_MASK,
            "files": [sparkle_build_file],
            "runOnlyForDeploymentPostprocessing": "0",
        },
    )
    add(
        app_resources_phase,
        {
            "isa": "PBXResourcesBuildPhase",
            "buildActionMask": MAX_BUILD_ACTION_MASK,
            "files": [catalog_build_file],
            "runOnlyForDeploymentPostprocessing": "0",
        },
    )
    add(
        app_scripts_phase,
        {
            "isa": "PBXShellScriptBuildPhase",
            "alwaysOutOfDate": "1",
            "buildActionMask": MAX_BUILD_ACTION_MASK,
            "files": [],
            "inputFileListPaths": [],
            "inputPaths": [
                '"$(SRCROOT)/Scripts/build_icons.sh"',
                '"$(SRCROOT)/Resources/AppIcon.svg"',
                '"$(SRCROOT)/Resources/MenuBarIcon.svg"',
            ],
            "name": "Generate icons",
            "outputFileListPaths": [],
            "outputPaths": [
                '"$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/AppIcon.icns"',
                '"$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/MenuBarIcon.png"',
            ],
            "runOnlyForDeploymentPostprocessing": "0",
            "shellPath": "/bin/bash",
            "shellScript": (
                'set -euo pipefail\n'
                '"/bin/bash" "$SRCROOT/Scripts/build_icons.sh" '
                '"$SRCROOT/Resources" "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"\n'
            ),
        },
    )
    add(
        cli_sources_phase,
        {
            "isa": "PBXSourcesBuildPhase",
            "buildActionMask": MAX_BUILD_ACTION_MASK,
            "files": cli_source_build_files,
            "runOnlyForDeploymentPostprocessing": "0",
        },
    )
    add(
        cli_frameworks_phase,
        {
            "isa": "PBXFrameworksBuildPhase",
            "buildActionMask": MAX_BUILD_ACTION_MASK,
            "files": [],
            "runOnlyForDeploymentPostprocessing": "0",
        },
    )

    add(
        tests_sources_phase,
        {
            "isa": "PBXSourcesBuildPhase",
            "buildActionMask": MAX_BUILD_ACTION_MASK,
            "files": test_source_build_files,
            "runOnlyForDeploymentPostprocessing": "0",
        },
    )
    add(
        tests_frameworks_phase,
        {
            "isa": "PBXFrameworksBuildPhase",
            "buildActionMask": MAX_BUILD_ACTION_MASK,
            "files": [],
            "runOnlyForDeploymentPostprocessing": "0",
        },
    )
    add(
        tests_resources_phase,
        {
            "isa": "PBXResourcesBuildPhase",
            "buildActionMask": MAX_BUILD_ACTION_MASK,
            "files": [],
            "runOnlyForDeploymentPostprocessing": "0",
        },
    )

    # ----------------------------------------------------------- build configs
    def configuration(name: str, settings: dict) -> str:
        return add(
            oid("config", name, str(sorted(settings.items()))),
            {
                "isa": "XCBuildConfiguration",
                "buildSettings": settings,
                "name": name,
            },
        )

    shared_settings = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "ARCHS": "arm64",
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "CODE_SIGN_IDENTITY": "-",
        "CODE_SIGN_STYLE": "Manual",
        "COPY_PHASE_STRIP": "NO",
        "DEVELOPMENT_LANGUAGE": "zh-Hans",
        "DEVELOPMENT_TEAM": "",
        "ENABLE_HARDENED_RUNTIME": "YES",
        # The icon phase reads files under $SRCROOT; the script sandbox blocks that.
        "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
        "GCC_NO_COMMON_BLOCKS": "YES",
        "GCC_WARN_UNDECLARED_SELECTOR": "YES",
        "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
        "MACOSX_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
        "SDKROOT": "macosx",
        "SWIFT_STRICT_CONCURRENCY": "complete",
        "SWIFT_TREAT_WARNINGS_AS_ERRORS": "YES",
        "SWIFT_VERSION": SWIFT_VERSION,
    }

    project_debug = configuration(
        "Debug",
        {
            **shared_settings,
            "DEBUG_INFORMATION_FORMAT": "dwarf",
            # Xcode 27 defaults Debug to the "debug dylib" layout, which leaves
            # the app's .swiftmodule in the intermediates instead of
            # BUILT_PRODUCTS_DIR, so a hosted test target cannot `@testable
            # import` it. Disabling also keeps the Debug bundle a single
            # executable, matching the script build.
            "ENABLE_DEBUG_DYLIB": "NO",
            "ENABLE_TESTABILITY": "YES",
            "GCC_OPTIMIZATION_LEVEL": "0",
            "ONLY_ACTIVE_ARCH": "YES",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
            "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
        },
    )
    project_release = configuration(
        "Release",
        {
            **shared_settings,
            "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
            "ENABLE_NS_ASSERTIONS": "NO",
            "SWIFT_COMPILATION_MODE": "wholemodule",
            "SWIFT_OPTIMIZATION_LEVEL": "-O",
        },
    )

    app_settings = {
        "CODE_SIGN_ENTITLEMENTS": "Resources/Debug.entitlements",
        "CURRENT_PROJECT_VERSION": BUILD_NUMBER,
        "EXECUTABLE_NAME": "XcodeSwitcherApp",
        "INFOPLIST_FILE": "Resources/Info.plist",
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/../Frameworks"],
        "MARKETING_VERSION": MARKETING_VERSION,
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_IDENTIFIER,
        "PRODUCT_MODULE_NAME": PROJECT_NAME,
        "PRODUCT_NAME": APP_PRODUCT_NAME,
        "SWIFT_EMIT_LOC_STRINGS": "YES",
    }
    app_debug = configuration("Debug", app_settings)
    app_release = configuration(
        "Release",
        {key: value for key, value in app_settings.items() if key != "CODE_SIGN_ENTITLEMENTS"},
    )

    # Hosted by the app so @testable import XcodeSwitcher resolves against the
    # app module, exactly like `swift test` does for the SwiftPM target.
    test_settings = {
        "BUNDLE_LOADER": "$(TEST_HOST)",
        "GENERATE_INFOPLIST_FILE": "YES",
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_IDENTIFIER + ".tests",
        "PRODUCT_NAME": TEST_TARGET,
        # An app target emits its .swiftmodule into the intermediates rather than
        # BUILT_PRODUCTS_DIR, so the hosted test target needs that directory on
        # its Swift search path to resolve `@testable import XcodeSwitcher`.
        "SWIFT_INCLUDE_PATHS": "$(CONFIGURATION_TEMP_DIR)/" + APP_TARGET + ".build/Objects-normal/$(CURRENT_ARCH)",
        "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/" + APP_PRODUCT + "/Contents/MacOS/XcodeSwitcherApp",
    }
    tests_debug = configuration("Debug", test_settings)
    tests_release = configuration("Release", dict(test_settings))

    cli_settings = {
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_IDENTIFIER + ".cli",
        "PRODUCT_NAME": CLI_PRODUCT,
        "SKIP_INSTALL": "YES",
    }
    cli_debug = configuration("Debug", cli_settings)
    cli_release = configuration("Release", dict(cli_settings))

    project_config_list = add(
        oid("configList", "project"),
        {
            "isa": "XCConfigurationList",
            "buildConfigurations": [project_debug, project_release],
            "defaultConfigurationIsVisible": "0",
            "defaultConfigurationName": "Release",
        },
    )
    app_config_list = add(
        oid("configList", APP_TARGET),
        {
            "isa": "XCConfigurationList",
            "buildConfigurations": [app_debug, app_release],
            "defaultConfigurationIsVisible": "0",
            "defaultConfigurationName": "Release",
        },
    )
    cli_config_list = add(
        oid("configList", CLI_TARGET),
        {
            "isa": "XCConfigurationList",
            "buildConfigurations": [cli_debug, cli_release],
            "defaultConfigurationIsVisible": "0",
            "defaultConfigurationName": "Release",
        },
    )

    tests_config_list = add(
        oid("configList", TEST_TARGET),
        {
            "isa": "XCConfigurationList",
            "buildConfigurations": [tests_debug, tests_release],
            "defaultConfigurationIsVisible": "0",
            "defaultConfigurationName": "Release",
        },
    )

    # ----------------------------------------------------------------- targets
    app_target = add(
        oid("target", APP_TARGET),
        {
            "isa": "PBXNativeTarget",
            "buildConfigurationList": app_config_list,
            "buildPhases": [
                app_sources_phase,
                app_frameworks_phase,
                app_resources_phase,
                app_scripts_phase,
                cli_copy_phase,
            ],
            "buildRules": [],
            "dependencies": [cli_dependency],
            "name": APP_TARGET,
            "packageProductDependencies": [sparkle_product],
            "productName": APP_TARGET,
            "productReference": app_product_ref,
            "productType": "com.apple.product-type.application",
        },
    )
    cli_target = add(
        oid("target", CLI_TARGET),
        {
            "isa": "PBXNativeTarget",
            "buildConfigurationList": cli_config_list,
            "buildPhases": [cli_sources_phase, cli_frameworks_phase],
            "buildRules": [],
            "dependencies": [],
            "name": CLI_TARGET,
            "productName": CLI_PRODUCT,
            "productReference": cli_product_ref,
            "productType": "com.apple.product-type.tool",
        },
    )

    tests_target = add(
        oid("target", TEST_TARGET),
        {
            "isa": "PBXNativeTarget",
            "buildConfigurationList": tests_config_list,
            "buildPhases": [tests_sources_phase, tests_frameworks_phase, tests_resources_phase],
            "buildRules": [],
            "dependencies": [app_dependency],
            "name": TEST_TARGET,
            "productName": TEST_TARGET,
            "productReference": tests_product_ref,
            "productType": "com.apple.product-type.bundle.unit-test",
        },
    )

    # ------------------------------------------------------------------ groups
    add(
        sources_group,
        {
            "isa": "PBXGroup",
            "children": [source_refs[name] for name in APP_SOURCES],
            "path": "Sources",
            "sourceTree": "<group>",
        },
    )
    add(
        cli_sources_group,
        {
            "isa": "PBXGroup",
            "children": [cli_main_ref],
            "path": "SourcesCLI",
            "sourceTree": "<group>",
        },
    )
    add(
        resources_group,
        {
            "isa": "PBXGroup",
            "children": [app_icon_ref, menu_icon_ref, catalog_ref, info_plist_ref, entitlements_ref],
            "path": "Resources",
            "sourceTree": "<group>",
        },
    )
    add(
        scripts_group,
        {
            "isa": "PBXGroup",
            "children": [build_icons_ref],
            "path": "Scripts",
            "sourceTree": "<group>",
        },
    )
    add(
        tests_group,
        {
            "isa": "PBXGroup",
            "children": [test_source_refs[name] for name in TEST_SOURCES],
            "path": "Tests",
            "sourceTree": "<group>",
        },
    )
    add(
        products_group,
        {
            "isa": "PBXGroup",
            "children": [app_product_ref, cli_product_ref, tests_product_ref],
            "name": "Products",
            "sourceTree": "<group>",
        },
    )
    add(
        main_group,
        {
            "isa": "PBXGroup",
            "children": [
                sources_group,
                cli_sources_group,
                tests_group,
                resources_group,
                scripts_group,
                products_group,
            ],
            "sourceTree": "<group>",
        },
    )

    project = add(
        oid("project"),
        {
            "isa": "PBXProject",
            "attributes": {
                "BuildIndependentTargetsInParallel": "1",
                "LastSwiftUpdateCheck": "2700",
                "LastUpgradeCheck": "2700",
            },
            "buildConfigurationList": project_config_list,
            "compatibilityVersion": "Xcode 15.0",
            "developmentRegion": "zh-Hans",
            "hasScannedForEncodings": "0",
            "knownRegions": ["zh-Hans", "en", "Base"],
            "mainGroup": main_group,
            "packageReferences": [sparkle_reference],
            "productRefGroup": products_group,
            "projectDirPath": "",
            "projectRoot": "",
            "targets": [app_target, cli_target, tests_target],
        },
    )

    return objects, project


def scheme_xml(
    target_id: str,
    target_name: str,
    product: str,
    is_app: bool,
    test_target_id: str | None = None,
) -> str:
    buildable = (
        f'            <BuildableReference\n'
        f'               BuildableIdentifier = "primary"\n'
        f'               BlueprintIdentifier = "{target_id}"\n'
        f'               BuildableName = "{product}"\n'
        f'               BlueprintName = "{target_name}"\n'
        f'               ReferencedContainer = "container:{PROJECT_NAME}.xcodeproj">\n'
        f'            </BuildableReference>\n'
    )
    runnable = (
        f'         <BuildableReference\n'
        f'            BuildableIdentifier = "primary"\n'
        f'            BlueprintIdentifier = "{target_id}"\n'
        f'            BuildableName = "{product}"\n'
        f'            BlueprintName = "{target_name}"\n'
        f'            ReferencedContainer = "container:{PROJECT_NAME}.xcodeproj">\n'
        f'         </BuildableReference>\n'
    )
    launch = (
        f'      <BuildableProductRunnable\n'
        f'         runnableDebuggingMode = "0">\n'
        f'{runnable}'
        f'      </BuildableProductRunnable>\n'
        if is_app
        else ""
    )
    testables = ""
    test_build_entry = ""
    if test_target_id is not None:
        testables = (
            '         <TestableReference\n'
            '            skipped = "NO">\n'
            '            <BuildableReference\n'
            '               BuildableIdentifier = "primary"\n'
            f'               BlueprintIdentifier = "{test_target_id}"\n'
            f'               BuildableName = "{TEST_PRODUCT}"\n'
            f'               BlueprintName = "{TEST_TARGET}"\n'
            f'               ReferencedContainer = "container:{PROJECT_NAME}.xcodeproj">\n'
            '            </BuildableReference>\n'
            '         </TestableReference>\n'
        )
        test_build_entry = (
            '         <BuildActionEntry\n'
            '            buildForTesting = "YES"\n'
            '            buildForRunning = "NO"\n'
            '            buildForProfiling = "NO"\n'
            '            buildForArchiving = "NO"\n'
            '            buildForAnalyzing = "NO">\n'
            '            <BuildableReference\n'
            '               BuildableIdentifier = "primary"\n'
            f'               BlueprintIdentifier = "{test_target_id}"\n'
            f'               BuildableName = "{TEST_PRODUCT}"\n'
            f'               BlueprintName = "{TEST_TARGET}"\n'
            f'               ReferencedContainer = "container:{PROJECT_NAME}.xcodeproj">\n'
            '            </BuildableReference>\n'
            '         </BuildActionEntry>\n'
        )
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<Scheme\n'
        '   LastUpgradeVersion = "2700"\n'
        '   version = "1.7">\n'
        '   <BuildAction\n'
        '      parallelizeBuildables = "YES"\n'
        '      buildImplicitDependencies = "YES">\n'
        '      <BuildActionEntries>\n'
        '         <BuildActionEntry\n'
        '            buildForTesting = "YES"\n'
        '            buildForRunning = "YES"\n'
        '            buildForProfiling = "YES"\n'
        '            buildForArchiving = "YES"\n'
        '            buildForAnalyzing = "YES">\n'
        f'{buildable}'
        '         </BuildActionEntry>\n'
        f'{test_build_entry}'
        '      </BuildActionEntries>\n'
        '   </BuildAction>\n'
        '   <TestAction\n'
        '      buildConfiguration = "Debug"\n'
        '      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"\n'
        '      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"\n'
        '      shouldUseLaunchSchemeArgsEnv = "YES">\n'
        '      <Testables>\n'
        f'{testables}'
        '      </Testables>\n'
        '   </TestAction>\n'
        '   <LaunchAction\n'
        '      buildConfiguration = "Debug"\n'
        '      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"\n'
        '      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"\n'
        '      launchStyle = "0"\n'
        '      useCustomWorkingDirectory = "NO"\n'
        '      ignoresPersistentStateOnLaunch = "NO"\n'
        '      debugDocumentVersioning = "YES"\n'
        '      debugServiceExtension = "internal"\n'
        '      allowLocationSimulation = "YES">\n'
        f'{launch}'
        '   </LaunchAction>\n'
        '   <ProfileAction\n'
        '      buildConfiguration = "Release"\n'
        '      shouldUseLaunchSchemeArgsEnv = "YES"\n'
        '      savedToolIdentifier = ""\n'
        '      useCustomWorkingDirectory = "NO"\n'
        '      debugDocumentVersioning = "YES">\n'
        '   </ProfileAction>\n'
        '   <AnalyzeAction\n'
        '      buildConfiguration = "Debug">\n'
        '   </AnalyzeAction>\n'
        '   <ArchiveAction\n'
        '      buildConfiguration = "Release"\n'
        '      revealArchiveInOrganizer = "YES">\n'
        '   </ArchiveAction>\n'
        '</Scheme>\n'
    )


def main() -> None:
    objects, project_id = build_objects()
    lines: list[str] = []
    emit(
        {
            "archiveVersion": "1",
            "objectVersion": "77",
            "objects": objects,
            "rootObject": project_id,
        },
        lines,
    )
    body = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        '<plist version="1.0">\n'
        + "\n".join(lines)
        + "\n</plist>\n"
    )

    (PROJECT_DIR / "project.pbxproj").parent.mkdir(parents=True, exist_ok=True)
    (PROJECT_DIR / "project.pbxproj").write_text(body, encoding="utf-8")

    workspace_dir = PROJECT_DIR / "project.xcworkspace"
    workspace_dir.mkdir(parents=True, exist_ok=True)
    (workspace_dir / "contents.xcworkspacedata").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<Workspace\n'
        '   version = "1.0">\n'
        '   <FileRef\n'
        '      location = "self:">\n'
        '   </FileRef>\n'
        '</Workspace>\n',
        encoding="utf-8",
    )

    schemes_dir = PROJECT_DIR / "xcshareddata" / "xcschemes"
    schemes_dir.mkdir(parents=True, exist_ok=True)
    (schemes_dir / f"{APP_SCHEME}.xcscheme").write_text(
        scheme_xml(
            oid("target", APP_TARGET),
            APP_TARGET,
            APP_PRODUCT,
            True,
            test_target_id=oid("target", TEST_TARGET),
        ),
        encoding="utf-8",
    )
    (schemes_dir / f"{CLI_SCHEME}.xcscheme").write_text(
        scheme_xml(oid("target", CLI_TARGET), CLI_TARGET, CLI_PRODUCT, False),
        encoding="utf-8",
    )

    for stale in schemes_dir.glob("*.xcscheme"):
        if stale.stem not in {APP_SCHEME, CLI_SCHEME}:
            stale.unlink()

    print(f"已生成 {PROJECT_DIR.relative_to(ROOT)}/project.pbxproj（{len(objects)} 个对象）")
    print("共享 scheme：", ", ".join(sorted(p.name for p in schemes_dir.iterdir())))


if __name__ == "__main__":
    main()
