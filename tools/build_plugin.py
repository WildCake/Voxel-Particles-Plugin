#!/usr/bin/env python3
"""Build and verify the Voxel Particles Roblox plugin from its disk manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
import uuid
import xml.etree.ElementTree as ET


PLUGIN_ROOT = Path(__file__).resolve().parents[1]
MANIFEST_PATH = PLUGIN_ROOT / "plugin-package.json"
SOURCEMAP_PATH = PLUGIN_ROOT / "plugin-sourcemap.json"
GUID_NAMESPACE = uuid.UUID("ee00e187-66ab-52c7-8b83-46e34527fd50")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--template",
        type=Path,
        required=True,
        help="Existing .rbxmx whose non-source Roblox metadata is preserved",
    )
    parser.add_argument(
        "--output",
        type=Path,
        required=True,
        help="Separate .rbxmx release artifact; may not overwrite the template",
    )
    return parser.parse_args()


def read_utf8(path: Path) -> str:
    raw = path.read_bytes()
    if raw.startswith(b"\xef\xbb\xbf"):
        raw = raw[3:]
    return raw.decode("utf-8", errors="strict")


def normalize_newlines(text: str) -> str:
    return text.replace("\r\n", "\n").replace("\r", "\n")


def load_manifest() -> dict:
    manifest = json.loads(read_utf8(MANIFEST_PATH))
    required = {
        "pluginName",
        "pluginVersion",
        "runtimeVersion",
        "installerVersion",
        "sourceRoot",
        "entrySource",
        "internalModules",
        "bundledPresets",
    }
    missing = sorted(required.difference(manifest))
    if missing:
        raise RuntimeError("Manifest is missing: " + ", ".join(missing))
    for list_name in ("internalModules", "bundledPresets"):
        values = manifest[list_name]
        if not isinstance(values, list) or not values or len(values) != len(set(values)):
            raise RuntimeError(f"Manifest {list_name} must be a non-empty unique list")
    return manifest


def source_paths(manifest: dict) -> tuple[Path, dict[str, Path], dict[str, Path]]:
    source_root = PLUGIN_ROOT / manifest["sourceRoot"]
    entry = source_root / manifest["entrySource"]
    internal = {
        name: source_root / "Internal" / f"{name}.luau"
        for name in manifest["internalModules"]
    }
    presets = {
        name: source_root / "Internal" / "BundledPresets" / f"{name}.luau"
        for name in manifest["bundledPresets"]
    }
    all_paths = [entry, *internal.values(), *presets.values()]
    missing = [str(path) for path in all_paths if not path.is_file()]
    if missing:
        raise RuntimeError("Manifest source files are missing:\n" + "\n".join(missing))

    # The analyzer map is part of the same package contract and may not drift.
    sourcemap = json.loads(read_utf8(SOURCEMAP_PATH))
    mapped_paths: set[str] = set()

    def collect_paths(node: dict) -> None:
        mapped_paths.update(node.get("filePaths", []))
        for child in node.get("children", []):
            collect_paths(child)

    collect_paths(sourcemap)
    expected_paths = {
        path.relative_to(PLUGIN_ROOT).as_posix()
        for path in all_paths
    }
    if mapped_paths != expected_paths:
        raise RuntimeError(
            "Analyzer sourcemap manifest mismatch: "
            f"missing={sorted(expected_paths - mapped_paths)}, extra={sorted(mapped_paths - expected_paths)}"
        )
    return entry, internal, presets


def item_pattern(class_name: str, item_name: str) -> re.Pattern[str]:
    return re.compile(
        rf'<Item class="{re.escape(class_name)}" referent="[^"]+">'
        rf'(?:(?!</Item>).)*?<string name="Name">{re.escape(item_name)}</string>'
        rf'(?:(?!</Item>).)*?</Item>',
        re.DOTALL,
    )


def find_unique_item(document: str, class_name: str, item_name: str) -> re.Match[str] | None:
    matches = list(item_pattern(class_name, item_name).finditer(document))
    if len(matches) > 1:
        raise RuntimeError(f"Expected at most one {class_name} named {item_name}, found {len(matches)}")
    return matches[0] if matches else None


def replace_item_source(block: str, source: str) -> str:
    if "]]>" in source:
        raise RuntimeError("A source file contains the CDATA terminator ]]>")
    source_pattern = re.compile(
        r'(<ProtectedString name="Source"><!\[CDATA\[)(.*?)(\]\]></ProtectedString>)',
        re.DOTALL,
    )
    updated, count = source_pattern.subn(
        lambda match: match.group(1) + source + match.group(3),
        block,
        count=1,
    )
    if count != 1:
        raise RuntimeError("Module item must contain exactly one CDATA Source property")
    return updated


def replace_item_name(block: str, old_name: str, new_name: str) -> str:
    old_property = f'<string name="Name">{old_name}</string>'
    new_property = f'<string name="Name">{new_name}</string>'
    if block.count(old_property) != 1:
        raise RuntimeError(f"Expected exactly one Name property for {old_name}")
    return block.replace(old_property, new_property, 1)


def clone_module_block(template_block: str, template_name: str, item_name: str, source: str) -> str:
    # Stable IDs make repeated builds from the same template byte-for-byte reproducible.
    referent = uuid.uuid5(GUID_NAMESPACE, f"referent/{item_name}")
    script_guid = uuid.uuid5(GUID_NAMESPACE, f"script-guid/{item_name}")
    clone, referent_count = re.subn(
        r'(<Item class="ModuleScript" referent=")([^"]+)(">)',
        lambda match: match.group(1) + "RBX" + referent.hex.upper() + match.group(3),
        template_block,
        count=1,
    )
    if referent_count != 1:
        raise RuntimeError("Module template is missing its referent")
    clone, guid_count = re.subn(
        r'(<string name="ScriptGuid">)\{[^}]+\}(</string>)',
        lambda match: match.group(1) + "{" + str(script_guid).upper() + "}" + match.group(2),
        clone,
        count=1,
    )
    if guid_count != 1:
        raise RuntimeError("Module template is missing its ScriptGuid")
    clone = replace_item_name(clone, template_name, item_name)
    return replace_item_source(clone, source)


def source_from_item(block: str) -> str:
    match = re.search(
        r'<ProtectedString name="Source"><!\[CDATA\[(.*?)\]\]></ProtectedString>',
        block,
        re.DOTALL,
    )
    if not match:
        raise RuntimeError("Unable to read Source from package item")
    return normalize_newlines(match.group(1))


def replace_existing_source(
    document: str,
    class_name: str,
    item_name: str,
    source: str,
) -> tuple[str, bool]:
    match = find_unique_item(document, class_name, item_name)
    if match is None:
        return document, False
    replacement = replace_item_source(match.group(0), source)
    return document[: match.start()] + replacement + document[match.end() :], True


def insert_cloned_module(
    document: str,
    after_name: str,
    item_name: str,
    source: str,
    newline: str,
) -> str:
    template = find_unique_item(document, "ModuleScript", after_name)
    if template is None:
        raise RuntimeError(f"Cannot clone missing ModuleScript template {after_name}")
    block = clone_module_block(template.group(0), after_name, item_name, source)
    return document[: template.end()] + newline + block + document[template.end() :]


def item_name(item: ET.Element) -> str:
    for child in item.find("Properties") or ():
        if child.tag == "string" and child.attrib.get("name") == "Name":
            return child.text or ""
    raise RuntimeError(f"Item {item.attrib.get('class')} has no Name property")


def direct_items(parent: ET.Element) -> list[ET.Element]:
    return [child for child in parent if child.tag == "Item"]


def validate_tree(document: str, manifest: dict) -> None:
    xml_root = ET.fromstring(document.encode("utf-8"))
    roots = direct_items(xml_root)
    if len(roots) != 1:
        raise RuntimeError(f"Package must contain one root item, found {len(roots)}")
    plugin_item = roots[0]
    if plugin_item.attrib.get("class") != "Script" or item_name(plugin_item) != manifest["pluginName"]:
        raise RuntimeError("Package root must be the VoxelParticlesPlugin Script")

    plugin_children = direct_items(plugin_item)
    if len(plugin_children) != 1:
        raise RuntimeError("Plugin Script must contain only the Internal folder")
    internal_folder = plugin_children[0]
    if internal_folder.attrib.get("class") != "Folder" or item_name(internal_folder) != "Internal":
        raise RuntimeError("Plugin Script child must be the Internal folder")

    internal_children = direct_items(internal_folder)
    module_names = {
        item_name(item)
        for item in internal_children
        if item.attrib.get("class") == "ModuleScript"
    }
    expected_modules = set(manifest["internalModules"])
    if module_names != expected_modules:
        raise RuntimeError(
            "Internal module manifest mismatch: "
            f"missing={sorted(expected_modules - module_names)}, extra={sorted(module_names - expected_modules)}"
        )
    non_modules = [item for item in internal_children if item.attrib.get("class") != "ModuleScript"]
    if len(non_modules) != 1:
        raise RuntimeError("Internal must contain exactly one non-module child: BundledPresets")
    preset_folder = non_modules[0]
    if preset_folder.attrib.get("class") != "Folder" or item_name(preset_folder) != "BundledPresets":
        raise RuntimeError("Internal non-module child must be the BundledPresets folder")

    preset_items = direct_items(preset_folder)
    if any(item.attrib.get("class") != "ModuleScript" for item in preset_items):
        raise RuntimeError("BundledPresets may contain only ModuleScripts")
    preset_names = {item_name(item) for item in preset_items}
    expected_presets = set(manifest["bundledPresets"])
    if preset_names != expected_presets:
        raise RuntimeError(
            "Bundled preset manifest mismatch: "
            f"missing={sorted(expected_presets - preset_names)}, extra={sorted(preset_names - expected_presets)}"
        )


def validate_sources(
    document: str,
    manifest: dict,
    entry_source: str,
    internal_sources: dict[str, str],
    preset_sources: dict[str, str],
) -> None:
    expected = [
        ("Script", manifest["pluginName"], entry_source),
        *(("ModuleScript", name, source) for name, source in internal_sources.items()),
        *(("ModuleScript", name, source) for name, source in preset_sources.items()),
    ]
    for class_name, name, source in expected:
        match = find_unique_item(document, class_name, name)
        if match is None:
            raise RuntimeError(f"Package is missing {class_name} {name}")
        if source_from_item(match.group(0)) != normalize_newlines(source):
            raise RuntimeError(f"Packaged source mismatch for {name}")

    internal_names = set(internal_sources)
    sibling_require = re.compile(
        r'require\(script\.Parent:WaitForChild\("([^"]+)"\)\)'
    )
    for owner, source in internal_sources.items():
        missing = sorted(set(sibling_require.findall(source)).difference(internal_names))
        if missing:
            raise RuntimeError(f"{owner} requires unbundled sibling modules: {', '.join(missing)}")

    plugin_version = manifest["pluginVersion"]
    runtime_version = manifest["runtimeVersion"]
    installer_version = manifest["installerVersion"]
    vps = internal_sources["VoxelParticleSystem"]
    cubic_bezier = internal_sources["VoxelCubicBezier"]
    quality = internal_sources["ClientVfxQuality"]
    installer = internal_sources["RuntimeInstaller"]
    required_markers = {
        "plugin entry": (
            entry_source,
            (
                f"local PLUGIN_VERSION = {plugin_version}",
                '"annulus"',
                '"radialOutward"',
                '"radialTangent"',
                '"cubicBezier"',
                '"curveNormal"',
                "spawnInnerRadius = state.spawnInnerRadius",
                "cubicBezierPoints = deepCopy(state.cubicBezierPoints)",
                "clone.Parent = module.Parent",
            ),
        ),
        "VoxelParticleSystem": (
            vps,
            (
                f"-- version {runtime_version}",
                'WaitForChild("ClientVfxQuality")',
                'WaitForChild("VoxelCubicBezier")',
                'spawnShape == "annulus"',
                'spawnShape == "cubicBezier"',
                'spawnDirectionMode == "radialOutward"',
                'spawnDirectionMode == "radialTangent"',
                'spawnDirectionMode == "curveNormal"',
                "function Emitter:SetCubicBezier",
            ),
        ),
        "VoxelCubicBezier": (
            cubic_bezier,
            (
                "function VoxelCubicBezier.Build",
                "function VoxelCubicBezier.Rebuild",
                "function VoxelCubicBezier.Sample",
                "cumulativeLengths",
            ),
        ),
        "ClientVfxQuality": (
            quality,
            ("GetParticleMultiplier", "OnTierChanged", "RollingFrameTimeMs"),
        ),
        "RuntimeInstaller": (
            installer,
            (
                f"local RUNTIME_VERSION = {runtime_version}",
                f"local INSTALLER_VERSION = {installer_version}",
                'ClientVfxQuality = Internal:WaitForChild("ClientVfxQuality")',
                'VoxelCubicBezier = Internal:WaitForChild("VoxelCubicBezier")',
            ),
        ),
    }
    for owner, (source, markers) in required_markers.items():
        missing = [marker for marker in markers if marker not in source]
        if missing:
            raise RuntimeError(f"{owner} contract markers are missing: {', '.join(missing)}")


def build_document(template: str, manifest: dict) -> str:
    entry_path, internal_paths, preset_paths = source_paths(manifest)
    entry_source = normalize_newlines(read_utf8(entry_path))
    internal_sources = {
        name: normalize_newlines(read_utf8(path)) for name, path in internal_paths.items()
    }
    preset_sources = {
        name: normalize_newlines(read_utf8(path)) for name, path in preset_paths.items()
    }
    newline = "\r\n" if "\r\n" in template else "\n"
    packaged = template

    packaged, found_entry = replace_existing_source(
        packaged,
        "Script",
        manifest["pluginName"],
        entry_source.replace("\n", newline),
    )
    if not found_entry:
        raise RuntimeError("Template is missing the VoxelParticlesPlugin Script")

    for name, source in internal_sources.items():
        packaged, found = replace_existing_source(
            packaged,
            "ModuleScript",
            name,
            source.replace("\n", newline),
        )
        if not found:
            packaged = insert_cloned_module(
                packaged,
                "VoxelParticleSystem",
                name,
                source.replace("\n", newline),
                newline,
            )

    for name, source in preset_sources.items():
        packaged, found = replace_existing_source(
            packaged,
            "ModuleScript",
            name,
            source.replace("\n", newline),
        )
        if not found:
            template_preset = next(
                (
                    preset_name
                    for preset_name in manifest["bundledPresets"]
                    if find_unique_item(packaged, "ModuleScript", preset_name) is not None
                ),
                None,
            )
            if template_preset is None:
                raise RuntimeError("Template has no bundled preset ModuleScript to clone")
            packaged = insert_cloned_module(
                packaged,
                template_preset,
                name,
                source.replace("\n", newline),
                newline,
            )

    validate_tree(packaged, manifest)
    validate_sources(packaged, manifest, entry_source, internal_sources, preset_sources)
    return packaged


def write_atomic(path: Path, document: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, staged_name = tempfile.mkstemp(
        prefix=f".{path.name}.",
        suffix=".tmp",
        dir=path.parent,
    )
    staged_path = Path(staged_name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(document.encode("utf-8"))
            stream.flush()
            os.fsync(stream.fileno())
        ET.parse(staged_path)
        os.replace(staged_path, path)
    except Exception:
        staged_path.unlink(missing_ok=True)
        raise


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def main() -> int:
    args = parse_args()
    template_path = args.template.resolve(strict=True)
    output_path = args.output.resolve()
    if template_path.suffix.lower() != ".rbxmx" or output_path.suffix.lower() != ".rbxmx":
        raise RuntimeError("Template and output must both use the .rbxmx extension")
    if template_path == output_path:
        raise RuntimeError("Output must be separate from the installed/template plugin")

    manifest = load_manifest()
    template = read_utf8(template_path)
    packaged = build_document(template, manifest)
    write_atomic(output_path, packaged)

    print(f"plugin_version={manifest['pluginVersion']}")
    print(f"runtime_version={manifest['runtimeVersion']}")
    print(f"installer_version={manifest['installerVersion']}")
    print(f"internal_modules={len(manifest['internalModules'])}")
    print(f"bundled_presets={len(manifest['bundledPresets'])}")
    print(f"sha256={sha256_text(packaged)}")
    print(f"output={output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
