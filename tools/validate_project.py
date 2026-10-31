"""Static checks that can run on Windows; this does NOT substitute for a Swift/Xcode build."""
import argparse
import json
import plistlib
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def validate(parser_path, report_path):
    if parser_path:
        sys.path.insert(0, str(parser_path))
    from openstep_parser import OpenStepDecoder
    import tree_sitter
    import tree_sitter_swift

    parser = tree_sitter.Parser(tree_sitter.Language(tree_sitter_swift.language()))
    swift_files = sorted(f for f in list((ROOT / "SeekAPI").rglob("*.swift")) + list((ROOT / "Packages").rglob("*.swift")) + list((ROOT / "SeekActivity").rglob("*.swift")) + list((ROOT / "SeekShare").rglob("*.swift"))
                         if ".build" not in f.parts)
    errors = []
    for file in swift_files:
        tree = parser.parse(file.read_bytes())
        if tree.root_node.has_error:
            def visit(node):
                if node.type == "ERROR" or node.is_missing:
                    errors.append(f"{file.relative_to(ROOT)}:{node.start_point.row + 1} {node.type}")
                for child in node.children:
                    visit(child)
            visit(tree.root_node)
    assert not errors, "Swift syntax errors: " + "; ".join(errors)
    with (ROOT / "SeekAPI.xcodeproj/project.pbxproj").open(encoding="utf-8") as file:
        project = OpenStepDecoder.ParseFromFile(file)
    objects = project["objects"]
    assert objects[project["rootObject"]]["isa"] == "PBXProject"
    resolved = {}

    def resolve_group(uid, parent):
        item = objects[uid]
        folder = parent / item.get("path", "")
        for child in item.get("children", []):
            obj = objects[child]
            if obj["isa"] == "PBXGroup":
                resolve_group(child, folder)
            elif obj["isa"] == "PBXFileReference" and obj.get("sourceTree") != "BUILT_PRODUCTS_DIR":
                path = (ROOT if obj.get("sourceTree") == "SOURCE_ROOT" else folder) / obj["path"]
                assert path.exists(), f"Missing Xcode file reference: {path}"
                resolved[child] = path

    resolve_group(objects[project["rootObject"]]["mainGroup"], ROOT)
    app_sources = {f.resolve() for f in swift_files if any(f.is_relative_to(ROOT / name) for name in ("SeekAPI", "SeekActivity", "SeekShare"))}
    app_sources.add((ROOT / "Packages/SeekCore/Sources/SeekCore/AttachmentFiles.swift").resolve())
    build_sources = set()
    for item in objects.values():
        if item["isa"] == "PBXSourcesBuildPhase":
            for uid in item["files"]:
                build_sources.add(resolved[objects[uid]["fileRef"]].resolve())
        if item["isa"] == "XCLocalSwiftPackageReference":
            assert (ROOT / item["relativePath"] / "Package.swift").is_file()
    assert app_sources == build_sources, "Xcode Sources phases do not match app/activity files"
    def target_sources(name):
        target = next(v for v in objects.values() if v["isa"] == "PBXNativeTarget" and v["name"] == name)
        refs = [objects[ref] for ref in target["buildPhases"] if objects[ref]["isa"] == "PBXSourcesBuildPhase"]
        return {resolved[objects[uid]["fileRef"]].resolve() for phase in refs for uid in phase["files"]}
    expected_app = {f.resolve() for f in (ROOT / "SeekAPI").rglob("*.swift")}
    expected_activity = {(ROOT / "SeekActivity/SeekReplyWidget.swift").resolve(),
                         (ROOT / "SeekAPI/Services/ReplyActivityAttributes.swift").resolve()}
    assert target_sources("SeekAPI") == expected_app
    assert target_sources("SeekActivity") == expected_activity
    expected_share = {(ROOT / "SeekShare/ShareViewController.swift").resolve(), (ROOT / "SeekAPI/Services/ShareInbox.swift").resolve(),
                      (ROOT / "Packages/SeekCore/Sources/SeekCore/AttachmentFiles.swift").resolve()}
    assert target_sources("SeekShare") == expected_share
    plistlib.loads((ROOT / "SeekShare/Info.plist").read_bytes())
    for name in ("SeekAPI", "SeekShare"):
        entitlements = plistlib.loads((ROOT / f"Config/{name}.entitlements").read_bytes())
        assert entitlements["com.apple.security.application-groups"] == ["group.app.seekapi.ios"]
    assert any(v["isa"] == "PBXCopyFilesBuildPhase" and str(v.get("dstSubfolderSpec")) == "13" for v in objects.values())
    plistlib.loads((ROOT / "SeekActivity/Info.plist").read_bytes())
    for file in (ROOT / "SeekAPI/Resources").glob("*.plist"):
        plistlib.loads(file.read_bytes())
    plistlib.loads((ROOT / "Config/Info-xtool.plist").read_bytes())
    plistlib.loads((ROOT / "SeekAPI/Resources/PrivacyInfo.xcprivacy").read_bytes())
    scheme = ET.parse(ROOT / "SeekAPI.xcodeproj/xcshareddata/xcschemes/SeekAPI.xcscheme")
    for element in scheme.iter("BuildableReference"):
        assert objects[element.attrib["BlueprintIdentifier"]]["isa"] == "PBXNativeTarget"
    for file in (ROOT / "SeekAPI/Resources/Assets.xcassets").rglob("Contents.json"):
        data = json.loads(file.read_text(encoding="utf-8"))
        for image in data.get("images", []):
            assert (file.parent / image["filename"]).is_file()
    tests = sum(len(re.findall(r"func test\w+\(", f.read_text(encoding="utf-8"))) for f in swift_files)
    report = {
        "checks": {"swift_grammar_parsing": True, "xcode_project_syntax_and_references": True,
                   "all_app_sources_in_build_phase": True, "activity_target_sources_and_embed_phase": True, "plists_schemes_assets": True},
        "swift_files_parsed": len(swift_files), "app_sources_in_target": len(expected_app), "activity_sources_in_target": len(expected_activity), "share_sources_in_target": len(expected_share),
        "core_xctest_cases_written": tests,
        "scope": "Static syntax, project references and resources only. See local-validation.json for execution results.",
        "macos_command": "bash scripts/verify_macos.sh"
    }
    report_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    args = argparse.ArgumentParser()
    args.add_argument("--parser-path", type=Path)
    args.add_argument("--report", type=Path, default=ROOT / "docs/static-validation.json")
    options = args.parse_args()
    validate(options.parser_path, options.report)
