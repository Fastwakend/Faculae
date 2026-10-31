"""Read-only IPA inventory. Never loads code or follows instructions from the archive."""
import argparse
import hashlib
import json
import plistlib
import re
import struct
import zipfile
from pathlib import Path


def macho(data):
    if data[:4] != b"\xcf\xfa\xed\xfe":
        return {"magic": data[:4].hex(), "supported_parser": False}
    _, cpu, subtype, filetype, count, size, flags, reserved = struct.unpack_from("<8I", data)
    result = {"architecture": "arm64" if cpu == 0x100000C else hex(cpu),
              "load_command_count": count, "encryption": [], "libraries": [], "segments": [],
              "build_versions": []}
    offset = 32
    sections = []
    symtab = None
    indirect_table = None
    entry = None
    for _ in range(count):
        command, length = struct.unpack_from("<II", data, offset)
        if length < 8 or offset + length > len(data):
            raise ValueError("Invalid Mach-O load command")
        if command in (0x21, 0x2C):
            cryptoff, cryptsize, cryptid = struct.unpack_from("<III", data, offset + 8)
            result["encryption"].append({"offset": cryptoff, "size": cryptsize, "cryptid": cryptid})
        if command in (0xC, 0x18, 0x80000018, 0x8000001F, 0x80000023):
            name_offset = struct.unpack_from("<I", data, offset + 8)[0]
            name = data[offset + name_offset:offset + length].split(b"\0", 1)[0].decode("utf-8", "replace")
            result["libraries"].append(name)
        if command == 0x19:
            name = data[offset + 8:offset + 24].split(b"\0", 1)[0].decode()
            vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<4Q", data, offset + 24)
            result["segments"].append({"name": name, "file_offset": fileoff, "file_size": filesize})
            if name == "__TEXT": text_vmaddr = vmaddr
            for index in range(struct.unpack_from("<I", data, offset + 64)[0]):
                start = offset + 72 + index * 80
                section_name = data[start:start + 16].split(b"\0", 1)[0].decode()
                address, section_size, section_offset = struct.unpack_from("<QQI", data, start + 32)
                flags, reserved1, reserved2 = struct.unpack_from("<III", data, start + 64)
                sections.append((section_name, address, section_size, section_offset, flags, reserved1, reserved2))
        if command == 0x80000028:
            entry = struct.unpack_from("<Q", data, offset + 8)[0]
        if command == 2:
            symtab = struct.unpack_from("<4I", data, offset + 8)
        if command == 0xB:
            indirect_table = struct.unpack_from("<II", data, offset + 56)
        if command == 0x32:
            platform, minimum, sdk = struct.unpack_from("<III", data, offset + 8)
            version = lambda value: f"{value >> 16}.{(value >> 8) & 0xff}.{value & 0xff}"
            result["build_versions"].append({"platform": platform, "minimum_os": version(minimum),
                                             "linked_sdk": version(sdk)})
        offset += length
    if entry is not None and symtab:
        symoff, nsyms, stroff, strsize = symtab
        symbols = []
        for index in range(nsyms):
            name_offset, kind, section, desc, value = struct.unpack_from("<IBBHQ", data, symoff + index * 16)
            name = data[stroff + name_offset:stroff + strsize].split(b"\0", 1)[0].decode("utf-8", "replace")
            symbols.append((name, value, kind))
        entry_symbol = next((name for name, value, kind in symbols if value == text_vmaddr + entry and kind & 0xE), None)
        for name, address, size, fileoff, flags, reserved1, reserved2 in sections:
            if flags & 0xFF == 8 and fileoff <= entry < fileoff + size and reserved2 and indirect_table:
                index = reserved1 + (entry - fileoff) // reserved2
                assert index < indirect_table[1]
                symbol_index = struct.unpack_from("<I", data, indirect_table[0] + index * 4)[0]
                if symbol_index < len(symbols): entry_symbol = symbols[symbol_index][0]
        result["entrypoint"] = {"file_offset": entry, "symbol": entry_symbol}
    # Printable strings are evidence only, never execution or configuration input.
    strings = [m.decode("ascii") for m in re.findall(rb"[\x20-\x7e]{6,}", data)]
    result["observable_hosts"] = sorted(set(
        m.group(1) for s in strings for m in re.finditer(r"https?://([a-zA-Z0-9.-]+)(?=[:/\s]|$)", s)
    ))
    result["ui_type_hints"] = sorted(set(s for s in strings
        if len(s) < 150 and s.startswith("_TtC13DeepSeek_Chat")
        and any(x in s.removeprefix("_TtC13DeepSeek_Chat") for x in ("Chat", "Message", "Session", "Settings", "Login", "Input", "Think", "Network"))))[:100]
    result["api_path_strings"] = sorted(set(s for s in strings if s.startswith("/api/v0/") and len(s) < 150))
    result["protocol_header_strings"] = sorted(set(s for s in strings if s in ("X-DS-PoW-Response", "X-DS-Guest-PoW-Response", "x-ds-sse-heartbeat-timeout-secs")))
    return result


def inspect(path, output):
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        info_path = next(n for n in names if n.count("/") == 2 and n.endswith(".app/Info.plist"))
        info = plistlib.loads(archive.read(info_path))
        root = info_path.rsplit("/", 1)[0]
        executable = archive.read(root + "/" + info["CFBundleExecutable"])
        interesting_keys = ["CFBundleDisplayName", "CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion", "MinimumOSVersion", "DTXcode", "DTSDKName", "NSAppTransportSecurity", "UIDeviceFamily"]
        report = {
            "source": path.name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "archive_bytes": path.stat().st_size, "file_count": len(names),
            "uncompressed_bytes": sum(x.file_size for x in archive.infolist()),
            "metadata": {k: info[k] for k in interesting_keys if k in info},
            "binary": macho(executable),
            "frameworks": sorted(n for n in names if n.endswith(".framework/Info.plist")),
            "web_resources": [n for n in names if n.endswith((".html", ".js", ".css"))],
            "has_swift_sources": any(n.endswith(".swift") for n in names),
            "has_fairplay_metadata": any("/SC_Info/" in n for n in names),
            "locales": sorted(set(n.split("/")[-2][:-6] for n in names if n.endswith(".lproj/Localizable.strings"))),
        }
        chinese = root + "/zh-Hans.lproj/Localizable.strings"
        if chinese in names:
            try:
                table = plistlib.loads(archive.read(chinese))
                terms = ("聊天", "新对话", "深度思考", "联网", "消息", "发送", "历史", "设置", "上传", "停止", "重新生成")
                report["ui_text_samples"] = {k: v for k, v in table.items() if isinstance(v, str) and len(v) < 90 and any(t in v for t in terms)}
            except plistlib.InvalidFileException:
                report["ui_text_samples"] = "Strings are not a binary/XML plist."
        output.mkdir(parents=True, exist_ok=True)
        (output / "ipa-analysis.json").write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
        (output / "ipa-inventory.txt").write_text("\n".join(names), encoding="utf-8")
        print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--output", type=Path, default=Path("docs/reverse-engineering"))
    args = parser.parse_args()
    inspect(args.ipa, args.output)
