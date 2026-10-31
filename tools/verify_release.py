"""Verify the arm64 IPA's resources, permissions and native control imports."""
import hashlib
import json
import plistlib
import struct
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def native_build_platform(platform, minimum, sdk):
    assert platform == 2 and minimum == 17 << 16, "Expected iOS with deployment target 17.0"
    assert sdk >= 26 << 16, "SDK metadata would opt native controls into the pre-Liquid Glass appearance"
    version = lambda value: f"{value >> 16}.{(value >> 8) & 0xff}.{value & 0xff}"
    return {"platform": "iOS", "minimum_os": version(minimum), "linked_sdk": version(sdk)}


def verify():
    ipa = ROOT / "artifacts/SeekAPI-unsigned.ipa"
    with zipfile.ZipFile(ipa) as archive:
        assert archive.testzip() is None
        prefix = "Payload/SeekAPI.app/"
        info = plistlib.loads(archive.read(prefix + "Info.plist"))
        expected = plistlib.loads((ROOT / "Config/Info-xtool.plist").read_bytes())
        for key in ("CFBundleDisplayName", "CFBundleName", "CFBundleShortVersionString", "CFBundleVersion", "NSCameraUsageDescription", "NSPhotoLibraryUsageDescription"):
            assert info[key] == expected[key], key
        assert info["CFBundleDisplayName"] == "Faculae"
        catalog_bytes = archive.read(prefix + "Assets.car")
        assert catalog_bytes.startswith(b"BOMStore")
        assert catalog_bytes == (ROOT / "artifacts/Faculae-Assets.car").read_bytes()
        catalog = json.loads((ROOT / "artifacts/asset-catalog.json").read_text(encoding="utf-8"))
        assert catalog["metadata"]["deployment_platform"] == "ios"
        assert catalog["header"]["key_semantics"] == 2
        assert ["UIAppearanceDark", 1] in catalog["appearances"]
        icon_variants = set()
        for rendition in catalog["renditions"]:
            attrs = dict(zip(catalog["keyformat"], rendition["key"]))
            if attrs.get(2) == 220 and rendition["width"] == rendition["height"] == 1024:
                appearance, idiom = attrs.get(7, 0), attrs.get(15, 0)
                assert rendition["name"] == ("AppIcon-Dark.png" if appearance == 1 else "AppIcon.png")
                icon_variants.add((appearance, idiom))
        assert {(0, 1), (1, 1), (0, 2), (1, 2)} <= icon_variants, "Missing light/dark iPhone/iPad primary icons"
        for key in ("CFBundleIcons", "CFBundleIcons~ipad"):
            primary = info[key]["CFBundlePrimaryIcon"]
            assert primary["CFBundleIconName"] == "AppIcon"
            assert primary["CFBundleIconFiles"]
            for stem in primary["CFBundleIconFiles"]:
                assert any(n.startswith(prefix + stem) and n.endswith(".png") for n in archive.namelist()), stem
        assert "CFBundleIconFile" not in info, "Legacy single-PNG metadata overrides the compiled icon"
        assert info["MinimumOSVersion"] == "17.0"
        assert info["NSSupportsLiveActivities"] is True
        assert info["NSSupportsLiveActivitiesFrequentUpdates"] is True
        assert info["NSPhotoLibraryAddUsageDescription"]
        assert set(info["UIBackgroundModes"]) == {"fetch", "processing", "location", "audio"}
        assert set(info["BGTaskSchedulerPermittedIdentifiers"]) == {"app.seekapi.ios.reply.refresh", "app.seekapi.ios.reply.processing", "app.seekapi.ios.reply.continued.*"}
        for key in ["NSLocationWhenInUseUsageDescription", "NSLocationAlwaysAndWhenInUseUsageDescription"]:
            assert info[key] and info[key] == expected[key]
        assert not info.get("UIDesignRequiresCompatibility", False)
        resources = ["ModelOpenAI", "ModelClaude", "ModelGemini", "ModelDeepSeek"]
        for name in resources:
            image = archive.read(prefix + name + ".png")
            assert image.startswith(b"\x89PNG\r\n\x1a\n")
            source = ROOT / f"SeekAPI/Resources/Assets.xcassets/{name}.imageset/{name}.png"
            assert image == source.read_bytes()
        license = archive.read(prefix + "ModelLogoLicenses.txt")
        assert b"MIT License" in license and b"Copyright (c) 2023 LobeHub" in license
        renderer_root = ROOT / "SeekAPI/Resources/MarkdownRenderer"
        manifest = json.loads((renderer_root / "manifest.json").read_text(encoding="utf-8"))
        for resource in manifest["files"]:
            content = archive.read(prefix + "MarkdownRenderer/" + resource["path"])
            assert len(content) == resource["bytes"]
            assert hashlib.sha256(content).hexdigest() == resource["sha256"], resource["path"]
            assert content == (renderer_root / resource["path"]).read_bytes()
        assert archive.read(prefix + "MarkdownRenderer/manifest.json") == (renderer_root / "manifest.json").read_bytes()
        assert {"index.html", "renderer.js", "renderer.css", "katex.css", "mermaid.js", "ThirdPartyNotices.txt"} <= {r["path"] for r in manifest["files"]}
        privacy = plistlib.loads(archive.read(prefix + "PrivacyInfo.xcprivacy"))
        assert any(x["NSPrivacyAccessedAPIType"] == "NSPrivacyAccessedAPICategoryUserDefaults" and
                   "CA92.1" in x["NSPrivacyAccessedAPITypeReasons"] for x in privacy["NSPrivacyAccessedAPITypes"])
        data = archive.read(prefix + info["CFBundleExecutable"])
        assert archive.read(prefix + "WebPLicense.txt") == (ROOT / "SeekAPI/Resources/WebPLicense.txt").read_bytes()
        assert b"WebPEncodeRGBA" in data and b"WebPEncodeLosslessRGBA" in data, "Generated WebP encoder is missing"
        activity_prefix = prefix + "PlugIns/SeekActivity.appex/"
        activity_info = plistlib.loads(archive.read(activity_prefix + "Info.plist"))
        assert activity_info["CFBundleDisplayName"] == "Faculae 回复状态"
        assert activity_info["CFBundleIdentifier"] == info["CFBundleIdentifier"] + ".activity"
        assert activity_info["CFBundleVersion"] == info["CFBundleVersion"]
        assert activity_info["CFBundleShortVersionString"] == info["CFBundleShortVersionString"]
        assert activity_info["NSExtension"]["NSExtensionPointIdentifier"] == "com.apple.widgetkit-extension"
        share_prefix = prefix + "PlugIns/SeekShare.appex/"
        share_info = plistlib.loads(archive.read(share_prefix + "Info.plist"))
        assert share_info["CFBundleDisplayName"] == "Faculae"
        assert share_info["CFBundleIdentifier"] == info["CFBundleIdentifier"] + ".share"
        assert share_info["CFBundleVersion"] == info["CFBundleVersion"]
        assert share_info["CFBundleShortVersionString"] == info["CFBundleShortVersionString"]
        assert share_info["NSExtension"]["NSExtensionPointIdentifier"] == "com.apple.share-services"
        assert share_info["NSExtension"]["NSExtensionPrincipalClass"] == "SeekShareViewController"
        rule = share_info["NSExtension"]["NSExtensionAttributes"]["NSExtensionActivationRule"]
        assert isinstance(rule, dict) and rule["NSExtensionActivationSupportsFileWithMaxCount"] == 6
        assert info["LSSupportsOpeningDocumentsInPlace"] is True
        assert info["UIFileSharingEnabled"] is True
        assert info["CFBundleDocumentTypes"][0]["LSItemContentTypes"] == ["public.data", "public.content"]
        assert plistlib.loads(archive.read(share_prefix + "Signing.entitlements"))["com.apple.security.application-groups"] == ["group.app.seekapi.ios"]
        assert "NSExtensionPrincipalClass" not in activity_info["NSExtension"]
        activity_binary = archive.read(activity_prefix + activity_info["CFBundleExecutable"])
        assert activity_binary[:4] == b"\xcf\xfa\xed\xfe"
        assert struct.unpack_from("<I", activity_binary, 4)[0] == 0x100000C
        assert struct.unpack_from("<I", activity_binary, 12)[0] == 2  # MH_EXECUTE
        from inspect_ipa import macho
        activity_macho = macho(activity_binary)
        share_macho = macho(archive.read(share_prefix + share_info["CFBundleExecutable"]))
        assert share_macho.get("entrypoint", {}).get("symbol") == "_NSExtensionMain"
        assert share_macho["build_versions"][0]["platform"] == 2
        assert share_macho["build_versions"][0]["linked_sdk"] == activity_macho["build_versions"][0]["linked_sdk"]
        assert activity_macho.get("entrypoint", {}).get("symbol") == "_NSExtensionMain", "WidgetKit extension must bootstrap through Foundation"
        assert len(activity_macho["build_versions"]) == 1
        assert activity_macho["build_versions"][0]["platform"] == 2
        assert activity_macho["build_versions"][0]["minimum_os"] == "17.0.0"
        assert any("WidgetKit" in x for x in activity_macho["libraries"])
        assert any("ActivityKit" in x for x in activity_macho["libraries"])
        for name in resources:
            artwork = archive.read(activity_prefix + name + "@3x.png")
            assert artwork == (ROOT / "SeekActivity/Resources" / (name + "@3x.png")).read_bytes()
            assert artwork[:8] == b"\x89PNG\r\n\x1a\n" and struct.unpack_from(">II", artwork, 16) == (90, 90)
            assert activity_prefix + name + ".png" not in archive.namelist(), "Oversized original activity artwork"
        app_libraries = macho(data)["libraries"]
        for framework in ["ActivityKit", "BackgroundTasks", "UserNotifications", "CoreLocation", "AVFAudio"]:
            assert any(framework in x for x in app_libraries), framework
        assert b"beginBackgroundTaskWithName:expirationHandler:" in data
        for symbol in [b"BGContinuedProcessingTaskRequest", b"BGContinuedProcessingTask", b"AVAudioPlayer",
                       b"startUpdatingLocation", b"stopUpdatingLocation", b"setAllowsBackgroundLocationUpdates:"]:
            assert symbol in data, symbol
        assert data[:4] == b"\xcf\xfa\xed\xfe" and struct.unpack_from("<I", data, 4)[0] == 0x100000C
        count = struct.unpack_from("<I", data, 16)[0]
        offset = 32
        symtab = None
        build_platform = None
        for _ in range(count):
            command, size = struct.unpack_from("<II", data, offset)
            assert size >= 8 and offset + size <= len(data), "Invalid Mach-O load command"
            if command == 2:
                symtab = struct.unpack_from("<4I", data, offset + 8)
            if command == 0x32:
                platform, minimum, sdk = struct.unpack_from("<III", data, offset + 8)
                build_platform = native_build_platform(platform, minimum, sdk)
            offset += size
        assert symtab
        assert build_platform, "Missing LC_BUILD_VERSION"
        sdk_build = json.loads((ROOT / "artifacts/ios-sdk-build.json").read_text(encoding="utf-8"))
        sdk_parts = sdk_build["sdk_version"].split(".")
        sdk_parts += ["0"] * (3 - len(sdk_parts))
        assert build_platform["linked_sdk"] == ".".join(sdk_parts), "Linked SDK must match the actual Apple SDK"
        assert activity_macho["build_versions"][0]["linked_sdk"] == build_platform["linked_sdk"]
        symoff, nsyms, stroff, strsize = symtab
        strings = data[stroff:stroff + strsize]
        imports = []
        slider_imports = []
        switch_imports = []
        for index in range(nsyms):
            name_offset, kind, section, flags, value = struct.unpack_from("<IBBHQ", data, symoff + index * 16)
            if kind & 0xE0 or kind & 0xE or value != 0:
                continue
            name = strings[name_offset:].split(b"\0", 1)[0].decode("utf-8", "replace")
            if "glassEffect" in name or "GlassEffectContainer" in name or "GlassV11interactive" in name:
                imports.append({"symbol": name, "weak_import": bool(flags & 0x40)})
            if "SliderTick" in name or ("SliderV" in name and "enabledBounds" in name):
                slider_imports.append({"symbol": name, "weak_import": bool(flags & 0x40)})
            if "SwitchToggleStyle" in name:
                switch_imports.append({"symbol": name, "weak_import": bool(flags & 0x40)})
        assert len(imports) >= 3 and all(x["weak_import"] for x in imports)
        morph_imports = [x for x in imports if "glassEffectID" in x["symbol"] or "glassEffectTransition" in x["symbol"]]
        assert len(morph_imports) >= 2 and all(x["weak_import"] for x in morph_imports), "Missing native glass morphing APIs"
        assert b"UIScrollEdgeElementContainerInteraction" in strings, "Missing public native scroll-edge compositor"
        assert b"topEdgeEffect\0" in data, "Missing native top edge effect"
        assert b"GlassButtonStyle" in strings, "Missing Apple's native glass button style"
        assert len(slider_imports) >= 3 and all(x["weak_import"] for x in slider_imports)
        assert switch_imports, "The IPA must use Apple's native SwitchToggleStyle"
    out = ROOT / "docs/build-wsl"
    out.mkdir(exist_ok=True)
    (out / "liquid-glass-linkage.json").write_text(json.dumps(imports, indent=2) + "\n", encoding="utf-8")
    (out / "native-slider-linkage.json").write_text(json.dumps(slider_imports, indent=2) + "\n", encoding="utf-8")
    (out / "native-switch-linkage.json").write_text(json.dumps(switch_imports, indent=2) + "\n", encoding="utf-8")
    report = {
        "display_name": info["CFBundleDisplayName"],
        "version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
        "bytes": ipa.stat().st_size, "sha256": hashlib.sha256(ipa.read_bytes()).hexdigest(),
        "checks": {"zip_crc": True, "arm64": True, "minimum_ios_17": True,
                   "four_model_pngs_match_sources": True, "offline_markdown_resources_match_manifest": True, "camera_and_photo_permission_strings": True,
                   "model_logo_license": True, "user_defaults_privacy_reason": True,
                   "native_glass_weak_imports": True, "native_glass_button_style": True, "native_glass_morphing_weak_imports": True,
                   "native_soft_scroll_edge_effect": True, "native_ios26_stepped_slider_weak_imports": True,
                   "native_system_switch_style": True, "linked_sdk_enables_modern_appearance": True,
                   "linked_sdk_matches_apple_sdk": True, "no_legacy_design_opt_out": True},
        "offline_renderer": {"versions": manifest["versions"], "file_count": len(manifest["files"])},
        "native_glass_symbol_count": len(imports), "model_resources": resources,
        "native_glass_morphing_symbol_count": len(morph_imports),
        "native_slider_symbol_count": len(slider_imports),
        "native_switch_symbol_count": len(switch_imports),
        "build_platform": build_platform,
        "runtime_ui_verified": False
    }
    report["checks"].update(faculae_app_and_extension_names=True,
                            compiled_asset_catalog_embedded=True,
                            native_light_dark_primary_icons_iphone_ipad=True,
                            primary_icon_metadata_matches_catalog=True)
    report["app_icons"] = {"catalog_sha256": hashlib.sha256(catalog_bytes).hexdigest(),
                           "variants": [{"appearance": "dark" if appearance == 1 else "light", "idiom": "iphone" if idiom == 1 else "ipad"}
                                        for appearance, idiom in sorted(icon_variants)],
                           "compiler": "accord 98e463c15609b13c26ec8a2971c2248e7e1d544d",
                           "runtime_verified": False}
    report["checks"].update(native_widgetkit_extension_embedded=True, activity_extension_arm64=True,
                            activity_extension_matching_version=True,
                            extension_four_supplier_logos=True, activitykit_backgroundtasks_notifications_linked=True,
                            activity_artwork_30pt_at_3x=True,
                            activity_extension_foundation_entrypoint=True, live_activity_frequent_updates_declared=True,
                            photo_library_add_permission=True,
                            background_modes_and_registered_identifiers=True, live_activities_plist_enabled=True)
    report["activity_extension"] = {"bundle_id": activity_info["CFBundleIdentifier"], "binary": activity_macho,
                                    "runtime_verified": False}
    report["checks"].update(native_share_extension_embedded=True, share_extension_foundation_entrypoint=True,
                            share_extension_matching_version=True, open_in_document_types_registered=True,
                            share_app_group_entitlement_template=True)
    report["checks"].update(webp_encoder_linked=True, webp_license_embedded=True)
    report["checks"].update(continued_processing_task_api_linked_static=True,
                            continued_task_wildcard_declared=True,
                            location_and_audio_background_modes=True,
                            location_permission_strings=True,
                            corelocation_and_audio_player_linked_static=True)
    report["share_extension"] = {"bundle_id": share_info["CFBundleIdentifier"], "binary": share_macho,
                                 "app_group": "group.app.seekapi.ios", "signed_entitlement_verified": False,
                                 "runtime_verified": False}
    (out / "release-checks.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    verify()
