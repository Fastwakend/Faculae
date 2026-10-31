"""Generate the checked-in Xcode project without requiring XcodeGen or CocoaPods."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def ident(name):
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()


def quoted(value):
    return json.dumps(str(value), ensure_ascii=False)


def generate():
    objects = []
    sources = []
    resources = []

    def add(name, kind, fields):
        uid = ident(name)
        objects.append(f"\t\t{uid} = {{\n\t\t\tisa = {kind};\n{fields}\n\t\t}};")
        return uid

    def fields(**values):
        return "\n".join(f"\t\t\t{k} = {v};" for k, v in values.items())

    def array(values):
        return "(\n" + "".join(f"\t\t\t\t{x},\n" for x in values) + "\t\t\t)"

    def group(folder):
        children = []
        for item in sorted((ROOT / folder).iterdir()):
            rel = item.relative_to(ROOT).as_posix()
            renderer_folder = rel == "SeekAPI/Resources/MarkdownRenderer"
            if item.is_dir() and item.suffix != ".xcassets" and not renderer_folder:
                children.append(group(Path(rel)))
                continue
            filetype = {".swift": "sourcecode.swift", ".plist": "text.plist.xml", ".xcprivacy": "text.xml",
                        ".xcassets": "folder.assetcatalog", ".xcconfig": "text.xcconfig", ".png": "image.png"}.get(item.suffix, "text")
            if renderer_folder:
                filetype = "folder"
            ref = add("file:" + rel, "PBXFileReference", fields(lastKnownFileType=filetype, path=quoted(item.name), sourceTree=quoted("<group>")))
            children.append(ref)
            if item.suffix == ".swift":
                sources.append(add("build:" + rel, "PBXBuildFile", fields(fileRef=ref)))
            elif renderer_folder or item.suffix in (".xcassets", ".xcprivacy") or rel in ("SeekAPI/Resources/ModelLogoLicenses.txt", "SeekAPI/Resources/WebPLicense.txt"):
                resources.append(add("build:" + rel, "PBXBuildFile", fields(fileRef=ref)))
        return add("group:" + folder.as_posix(), "PBXGroup", fields(children=array(children), path=quoted(folder.name), sourceTree=quoted("<group>")))

    app_group = group(Path("SeekAPI"))
    config_group = group(Path("Config"))
    app_sources = list(sources)
    extension_group = group(Path("SeekActivity"))
    extension_sources = sources[len(app_sources):]
    sources[:] = app_sources
    share_group = group(Path("SeekShare"))
    share_sources = sources[len(app_sources):]
    sources[:] = app_sources
    share_sources.append(add("share-shared-build", "PBXBuildFile", fields(fileRef=ident("file:SeekAPI/Services/ShareInbox.swift"))))
    share_io = add("share-file-io", "PBXFileReference", fields(lastKnownFileType="sourcecode.swift", path=quoted("Packages/SeekCore/Sources/SeekCore/AttachmentFiles.swift"), sourceTree="SOURCE_ROOT"))
    share_sources.append(add("share-file-io-build", "PBXBuildFile", fields(fileRef=share_io)))
    share_io_group = add("share-file-io-group", "PBXGroup", fields(children=array([share_io]), name=quoted("Shared File IO"), sourceTree=quoted("<group>")))
    extension_sources.append(add("activity-shared-build", "PBXBuildFile", fields(fileRef=ident("file:SeekAPI/Services/ReplyActivityAttributes.swift"))))
    extension_resources = []
    for brand in ("OpenAI", "Claude", "Gemini", "DeepSeek"):
        rel = f"SeekActivity/Resources/Model{brand}@3x.png"
        ref = add("activity-logo:" + brand, "PBXFileReference", fields(lastKnownFileType="image.png", path=quoted(rel), sourceTree="SOURCE_ROOT"))
        extension_resources.append(add("activity-logo-build:" + brand, "PBXBuildFile", fields(fileRef=ref)))
    # Keep ActivityKit artwork within the system's Live Activity image size limit.
    logo_group = add("activity-logos", "PBXGroup", fields(children=array([ident("activity-logo:" + brand) for brand in ("OpenAI", "Claude", "Gemini", "DeepSeek")]), name=quoted("Activity Logos"), sourceTree=quoted("<group>")))
    extension_product = add("activity-product", "PBXFileReference", fields(explicitFileType=quoted("wrapper.app-extension"), includeInIndex="0", path=quoted("SeekActivity.appex"), sourceTree="BUILT_PRODUCTS_DIR"))
    share_product = add("share-product", "PBXFileReference", fields(explicitFileType=quoted("wrapper.app-extension"), includeInIndex="0", path=quoted("SeekShare.appex"), sourceTree="BUILT_PRODUCTS_DIR"))
    product = add("product", "PBXFileReference", fields(explicitFileType="wrapper.application", includeInIndex="0", path=quoted("SeekAPI.app"), sourceTree="BUILT_PRODUCTS_DIR"))
    products = add("products", "PBXGroup", fields(children=array([product, extension_product, share_product]), name="Products", sourceTree=quoted("<group>")))
    main_group = add("main-group", "PBXGroup", fields(children=array([app_group, extension_group, share_group, share_io_group, logo_group, config_group, products]), sourceTree=quoted("<group>")))
    package = add("core-package", "XCLocalSwiftPackageReference", fields(relativePath=quoted("Packages/SeekCore")))
    core_product = add("core-product", "XCSwiftPackageProductDependency", fields(productName="SeekCore"))
    core_build = add("core-build", "PBXBuildFile", fields(productRef=core_product))
    webp_package = add("webp-package", "XCLocalSwiftPackageReference", fields(relativePath=quoted("Packages/SeekWebP")))
    webp_product = add("webp-product", "XCSwiftPackageProductDependency", fields(productName="SeekWebP"))
    webp_build = add("webp-build", "PBXBuildFile", fields(productRef=webp_product))
    source_phase = add("sources", "PBXSourcesBuildPhase", fields(buildActionMask="2147483647", files=array(sources), runOnlyForDeploymentPostprocessing="0"))
    resource_phase = add("resources", "PBXResourcesBuildPhase", fields(buildActionMask="2147483647", files=array(resources), runOnlyForDeploymentPostprocessing="0"))
    framework_phase = add("frameworks", "PBXFrameworksBuildPhase", fields(buildActionMask="2147483647", files=array([core_build, webp_build]), runOnlyForDeploymentPostprocessing="0"))
    activity_source_phase = add("activity-sources", "PBXSourcesBuildPhase", fields(buildActionMask="2147483647", files=array(extension_sources), runOnlyForDeploymentPostprocessing="0"))
    activity_resource_phase = add("activity-resources", "PBXResourcesBuildPhase", fields(buildActionMask="2147483647", files=array(extension_resources), runOnlyForDeploymentPostprocessing="0"))
    activity_framework_phase = add("activity-frameworks", "PBXFrameworksBuildPhase", fields(buildActionMask="2147483647", files="()", runOnlyForDeploymentPostprocessing="0"))
    share_source_phase = add("share-sources", "PBXSourcesBuildPhase", fields(buildActionMask="2147483647", files=array(share_sources), runOnlyForDeploymentPostprocessing="0"))
    share_framework_phase = add("share-frameworks", "PBXFrameworksBuildPhase", fields(buildActionMask="2147483647", files="()", runOnlyForDeploymentPostprocessing="0"))
    embed_file = add("activity-embed-file", "PBXBuildFile", fields(fileRef=extension_product, settings="{ATTRIBUTES = (RemoveHeadersOnCopy,);}"))
    share_embed_file = add("share-embed-file", "PBXBuildFile", fields(fileRef=share_product, settings="{ATTRIBUTES = (RemoveHeadersOnCopy,);}"))
    embed_phase = add("activity-embed-phase", "PBXCopyFilesBuildPhase", fields(buildActionMask="2147483647", dstPath=quoted(""), dstSubfolderSpec="13", files=array([embed_file, share_embed_file]), name=quoted("Embed App Extensions"), runOnlyForDeploymentPostprocessing="0"))
    config_reference = ident("file:Config/Release.xcconfig")
    project_configs, target_configs, activity_configs, share_configs = [], [], [], []
    for name in ("Debug", "Release"):
        common = {"CLANG_ENABLE_MODULES": "YES", "SDKROOT": "iphoneos", "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
                  "SWIFT_VERSION": "5.0", "ENABLE_USER_SCRIPT_SANDBOXING": "YES"}
        if name == "Debug":
            common.update(SWIFT_OPTIMIZATION_LEVEL=quoted("-Onone"), SWIFT_ACTIVE_COMPILATION_CONDITIONS=quoted("DEBUG $(inherited)"), DEBUG_INFORMATION_FORMAT="dwarf", ONLY_ACTIVE_ARCH="YES")
        else:
            common.update(SWIFT_COMPILATION_MODE="wholemodule", SWIFT_OPTIMIZATION_LEVEL=quoted("-O"), DEBUG_INFORMATION_FORMAT=quoted("dwarf-with-dsym"))
        settings = "{\n" + "\n".join(f"\t\t\t\t{k} = {v};" for k, v in common.items()) + "\n\t\t\t}"
        project_configs.append(add("project-config:" + name, "XCBuildConfiguration", fields(buildSettings=settings, name=name)))
        target = {"ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon", "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
                  "GENERATE_INFOPLIST_FILE": "NO", "INFOPLIST_FILE": quoted("SeekAPI/Resources/Info.plist"),
                  "PRODUCT_NAME": quoted("$(TARGET_NAME)"), "SUPPORTED_PLATFORMS": quoted("iphoneos iphonesimulator"),
                  "SUPPORTS_MACCATALYST": "NO", "LD_RUNPATH_SEARCH_PATHS": quoted("$(inherited) @executable_path/Frameworks"),
                  "ENABLE_PREVIEWS": "YES", "CODE_SIGN_ENTITLEMENTS": quoted("Config/SeekAPI.entitlements")}
        settings = "{\n" + "\n".join(f"\t\t\t\t{k} = {v};" for k, v in target.items()) + "\n\t\t\t}"
        target_configs.append(add("target-config:" + name, "XCBuildConfiguration", fields(baseConfigurationReference=config_reference, buildSettings=settings, name=name)))
        activity_settings = {
            "APPLICATION_EXTENSION_API_ONLY": "YES", "CODE_SIGN_STYLE": "Automatic",
            "PRODUCT_BUNDLE_IDENTIFIER": quoted("$(SEEK_APP_BUNDLE_IDENTIFIER).activity"),
            "PRODUCT_NAME": "SeekActivity", "SKIP_INSTALL": "YES",
            "MARKETING_VERSION": "2.3.2", "CURRENT_PROJECT_VERSION": "34",
            "GENERATE_INFOPLIST_FILE": "NO", "INFOPLIST_FILE": quoted("SeekActivity/Info.plist"),
            "TARGETED_DEVICE_FAMILY": quoted("1,2"), "SUPPORTED_PLATFORMS": quoted("iphoneos iphonesimulator"),
            "LD_RUNPATH_SEARCH_PATHS": quoted("$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks")}
        settings = "{\n" + "\n".join(f"\t\t\t\t{k} = {v};" for k, v in activity_settings.items()) + "\n\t\t\t}"
        activity_configs.append(add("activity-config:" + name, "XCBuildConfiguration", fields(baseConfigurationReference=config_reference, buildSettings=settings, name=name)))
        share_settings = dict(activity_settings, PRODUCT_BUNDLE_IDENTIFIER=quoted("$(SEEK_APP_BUNDLE_IDENTIFIER).share"),
                              PRODUCT_NAME="SeekShare", INFOPLIST_FILE=quoted("SeekShare/Info.plist"),
                              CODE_SIGN_ENTITLEMENTS=quoted("Config/SeekShare.entitlements"))
        settings = "{\n" + "\n".join(f"\t\t\t\t{k} = {v};" for k, v in share_settings.items()) + "\n\t\t\t}"
        share_configs.append(add("share-config:" + name, "XCBuildConfiguration", fields(baseConfigurationReference=config_reference, buildSettings=settings, name=name)))
    pc = add("project-configs", "XCConfigurationList", fields(buildConfigurations=array(project_configs), defaultConfigurationIsVisible="0", defaultConfigurationName="Release"))
    tc = add("target-configs", "XCConfigurationList", fields(buildConfigurations=array(target_configs), defaultConfigurationIsVisible="0", defaultConfigurationName="Release"))
    ac = add("activity-configs", "XCConfigurationList", fields(buildConfigurations=array(activity_configs), defaultConfigurationIsVisible="0", defaultConfigurationName="Release"))
    sc = add("share-configs", "XCConfigurationList", fields(buildConfigurations=array(share_configs), defaultConfigurationIsVisible="0", defaultConfigurationName="Release"))
    share_target = add("share-target", "PBXNativeTarget", fields(buildConfigurationList=sc, buildPhases=array([share_source_phase, share_framework_phase]), buildRules="()", dependencies="()", name="SeekShare", productName="SeekShare", productReference=share_product, productType=quoted("com.apple.product-type.app-extension")))
    share_proxy = add("share-proxy", "PBXContainerItemProxy", fields(containerPortal=ident("project"), proxyType="1", remoteGlobalIDString=share_target, remoteInfo="SeekShare"))
    share_dependency = add("share-dependency", "PBXTargetDependency", fields(target=share_target, targetProxy=share_proxy))
    activity_target = add("activity-target", "PBXNativeTarget", fields(buildConfigurationList=ac, buildPhases=array([activity_source_phase, activity_framework_phase, activity_resource_phase]), buildRules="()", dependencies="()", name="SeekActivity", productName="SeekActivity", productReference=extension_product, productType=quoted("com.apple.product-type.app-extension")))
    proxy = add("activity-proxy", "PBXContainerItemProxy", fields(containerPortal=ident("project"), proxyType="1", remoteGlobalIDString=activity_target, remoteInfo="SeekActivity"))
    dependency = add("activity-dependency", "PBXTargetDependency", fields(target=activity_target, targetProxy=proxy))
    target = add("app-target", "PBXNativeTarget", fields(buildConfigurationList=tc, buildPhases=array([source_phase, framework_phase, resource_phase, embed_phase]), buildRules="()", dependencies=array([dependency, share_dependency]), name="SeekAPI", packageProductDependencies=array([core_product, webp_product]), productName="SeekAPI", productReference=product, productType=quoted("com.apple.product-type.application")))
    project = add("project", "PBXProject", fields(attributes="{BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 1600;}", buildConfigurationList=pc, compatibilityVersion=quoted("Xcode 14.0"), developmentRegion=quoted("zh-Hans"), hasScannedForEncodings="0", knownRegions=array([quoted("zh-Hans"), "en", "Base"]), mainGroup=main_group, packageReferences=array([package, webp_package]), productRefGroup=products, projectDirPath=quoted(""), projectRoot=quoted(""), targets=array([target, activity_target, share_target])))
    project_folder = ROOT / "SeekAPI.xcodeproj"
    project_folder.mkdir(exist_ok=True)
    content = "// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n" + "\n".join(objects) + f"\n\t}};\n\trootObject = {project};\n}}\n"
    (project_folder / "project.pbxproj").write_text(content, encoding="utf-8")
    scheme = project_folder / "xcshareddata/xcschemes"
    scheme.mkdir(parents=True, exist_ok=True)
    reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="SeekAPI.app" BlueprintName="SeekAPI" ReferencedContainer="container:SeekAPI.xcodeproj"/>'
    (scheme / "SeekAPI.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.7">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry></BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables/></TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''', encoding="utf-8")
    workspace = project_folder / "project.xcworkspace"
    workspace.mkdir(exist_ok=True)
    (workspace / "contents.xcworkspacedata").write_text('<?xml version="1.0" encoding="UTF-8"?><Workspace version="1.0"><FileRef location="self:"/></Workspace>', encoding="utf-8")
    print(f"Generated {len(sources)} app + {len(extension_sources)} activity + {len(share_sources)} share sources; {len(resources)} resource bundles.")


if __name__ == "__main__":
    generate()
