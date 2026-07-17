#!/usr/bin/python3
"""Render the authoritative MDM-managed Claude tree without running kit code."""

import argparse
import copy
import hashlib
import json
import os
import re
import shutil
import stat
import sys
import unicodedata


MAX_CONFIG_BYTES = 4 * 1024 * 1024
MAX_FILE_BYTES = 64 * 1024 * 1024
MAX_TOTAL_BYTES = 128 * 1024 * 1024
MAX_FILES = 1_000
MAX_INVENTORY_PATHS = 2_000
MAX_RELATIVE_BYTES = 1024
MAX_DEPTH = 64
BEGIN_MARKER = "<!-- BEGIN STARTER-KIT-MANAGED -->"
END_MARKER = "<!-- END STARTER-KIT-MANAGED -->"
PROFILE_NAMES = ("minimal", "standard", "full")
GENERATED_MODE = 0o600
EXECUTABLE_MODE = 0o700


class RenderError(Exception):
    """Expected fail-closed renderer error."""


def fail(message):
    raise RenderError(message)


def validate_relative(path):
    if not isinstance(path, str) or not path:
        fail("empty relative path")
    if path.startswith("/") or "\\" in path:
        fail("invalid relative path: {!r}".format(path))
    parts = path.split("/")
    if len(parts) > MAX_DEPTH or any(part in ("", ".", "..") for part in parts):
        fail("invalid relative path: {!r}".format(path))
    if len(path.encode("utf-8", "strict")) > MAX_RELATIVE_BYTES:
        fail("relative path is too long: {!r}".format(path))
    for char in path:
        code = ord(char)
        if code < 0x20 or code == 0x7F or 0xD800 <= code <= 0xDFFF:
            fail("relative path contains a control character")
    return path


def mode_is_safe(mode):
    return mode & 0o022 == 0


def has_control(value):
    return any(ord(char) < 0x20 or ord(char) == 0x7F for char in value)


class Checkout:
    """Bounded, no-follow reads from an effective-user-owned checkout."""

    def __init__(self, root):
        if not os.path.isabs(root) or has_control(root):
            fail("checkout must be an absolute path")
        normalized = os.path.normpath(root)
        if normalized != root:
            fail("checkout path must already be normalized")
        root = normalized
        if root == "/":
            fail("checkout cannot be the filesystem root")
        self.root = root
        self.uid = os.geteuid()
        self.total_read = 0
        self._verified_directories = set()
        self._verify_directory("")

    def _absolute(self, relative):
        if relative:
            validate_relative(relative)
            return os.path.join(self.root, *relative.split("/"))
        return self.root

    def _verify_owned(self, info, label):
        if info.st_uid != self.uid:
            fail("checkout path has unexpected owner: {}".format(label))
        if not mode_is_safe(info.st_mode):
            fail("checkout path is group/other writable: {}".format(label))

    def _verify_directory(self, relative):
        if relative in self._verified_directories:
            return
        absolute = self._absolute(relative)
        try:
            info = os.lstat(absolute)
        except OSError as error:
            fail("cannot inspect checkout directory {}: {}".format(relative or ".", error))
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
            fail("checkout path is not a real directory: {}".format(relative or "."))
        self._verify_owned(info, relative or ".")
        self._verified_directories.add(relative)

    def _verify_parents(self, relative):
        parts = relative.split("/")[:-1]
        for index in range(1, len(parts) + 1):
            self._verify_directory("/".join(parts[:index]))

    def read(self, relative, limit=MAX_FILE_BYTES):
        validate_relative(relative)
        self._verify_parents(relative)
        absolute = self._absolute(relative)
        try:
            before = os.lstat(absolute)
        except OSError as error:
            fail("cannot inspect checkout file {}: {}".format(relative, error))
        if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
            fail("checkout path is not a regular file: {}".format(relative))
        self._verify_owned(before, relative)
        if before.st_size < 0 or before.st_size > limit:
            fail("checkout file exceeds size limit: {}".format(relative))
        if self.total_read + before.st_size > MAX_TOTAL_BYTES:
            fail("checkout data exceeds total size limit")

        flags = os.O_RDONLY
        flags |= getattr(os, "O_CLOEXEC", 0)
        flags |= getattr(os, "O_NOFOLLOW", 0)
        try:
            descriptor = os.open(absolute, flags)
        except OSError as error:
            fail("cannot open checkout file {}: {}".format(relative, error))
        try:
            opened = os.fstat(descriptor)
            identity = (
                before.st_dev,
                before.st_ino,
                before.st_size,
                before.st_uid,
                before.st_mode,
                before.st_mtime_ns,
            )
            opened_identity = (
                opened.st_dev,
                opened.st_ino,
                opened.st_size,
                opened.st_uid,
                opened.st_mode,
                opened.st_mtime_ns,
            )
            if identity != opened_identity or not stat.S_ISREG(opened.st_mode):
                fail("checkout file changed while opening: {}".format(relative))
            chunks = []
            remaining = before.st_size + 1
            while remaining:
                chunk = os.read(descriptor, min(1024 * 1024, remaining))
                if not chunk:
                    break
                chunks.append(chunk)
                remaining -= len(chunk)
            data = b"".join(chunks)
            after = os.fstat(descriptor)
            after_identity = (
                after.st_dev,
                after.st_ino,
                after.st_size,
                after.st_uid,
                after.st_mode,
                after.st_mtime_ns,
            )
            if len(data) != before.st_size or after_identity != identity:
                fail("checkout file changed while reading: {}".format(relative))
        finally:
            os.close(descriptor)
        self.total_read += len(data)
        return data, before.st_mode

    def read_text(self, relative, limit=MAX_CONFIG_BYTES):
        data, mode = self.read(relative, limit)
        try:
            text = data.decode("utf-8", "strict")
        except UnicodeDecodeError:
            fail("checkout text is not UTF-8: {}".format(relative))
        if "\x00" in text or "\r" in text:
            fail("checkout text contains unsupported control characters: {}".format(relative))
        return text, mode

    def tree(self, relative):
        """Return (relative path, bytes, source mode) for a managed source tree."""
        validate_relative(relative)
        self._verify_directory(relative)
        results = []

        def walk(current):
            absolute = self._absolute(current)
            try:
                entries = list(os.scandir(absolute))
            except OSError as error:
                fail("cannot enumerate checkout directory {}: {}".format(current, error))
            entries.sort(key=lambda entry: os.fsencode(entry.name))
            for entry in entries:
                child = current + "/" + entry.name
                output_rel = child[len(relative) + 1 :]
                validate_relative(output_rel)
                try:
                    info = entry.stat(follow_symlinks=False)
                except OSError as error:
                    fail("cannot inspect checkout path {}: {}".format(child, error))
                if stat.S_ISLNK(info.st_mode):
                    fail("symlink found in managed source tree: {}".format(child))
                self._verify_owned(info, child)
                if stat.S_ISDIR(info.st_mode):
                    self._verified_directories.add(child)
                    if entry.name in ("node_modules", "logs"):
                        continue
                    walk(child)
                elif stat.S_ISREG(info.st_mode):
                    if entry.name.endswith(".bak"):
                        continue
                    data, source_mode = self.read(child)
                    results.append((output_rel, data, source_mode))
                    if len(results) > MAX_FILES:
                        fail("managed source contains too many files")
                else:
                    fail("special file found in managed source tree: {}".format(child))

        walk(relative)
        return results


def parse_registry(checkout):
    text, _ = checkout.read_text("lib/features.sh")

    def association(name):
        pattern = r"declare -g -A {}=\(\n(.*?)\n\)".format(re.escape(name))
        matches = re.findall(pattern, text, re.DOTALL)
        if len(matches) != 1:
            fail("unsupported feature registry: {}".format(name))
        result = {}
        for raw in matches[0].split("\n"):
            line = raw.strip()
            if not line:
                continue
            match = re.fullmatch(r"\[([a-z0-9][a-z0-9-]*)\]=([A-Z][A-Z0-9_]*|true)", line)
            if not match or match.group(1) in result:
                fail("invalid feature registry entry in {}".format(name))
            result[match.group(1)] = match.group(2)
        return result

    flags = association("_FEATURE_FLAGS")
    script_features = association("_FEATURE_HAS_SCRIPTS")
    order_matches = re.findall(
        r"declare -g -a _FEATURE_ORDER=\(\n(.*?)\n\)", text, re.DOTALL
    )
    if len(order_matches) != 1:
        fail("unsupported feature order registry")
    order = re.findall(r"[a-z0-9][a-z0-9-]*", order_matches[0])
    if not order or order[0] != "safety-net" or len(order) != len(set(order)):
        fail("invalid feature order registry")
    if set(flags) != set(order):
        fail("feature flags and order registry differ")
    if not set(script_features).issubset(flags) or any(
        value != "true" for value in script_features.values()
    ):
        fail("invalid script feature registry")
    alias = 'declare -g -a _FEATURE_SCRIPT_ORDER=("${_FEATURE_ORDER[@]}")'
    if text.count(alias) != 1:
        fail("unsupported script feature order registry")
    return flags, order, script_features


def parse_profile(checkout, selected, required_flags):
    profiles = {}
    for name in PROFILE_NAMES:
        text, _ = checkout.read_text("profiles/{}.conf".format(name))
        values = {}
        for raw in text.split("\n"):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            match = re.fullmatch(r"([A-Z][A-Z0-9_]*)=(true|false)", line)
            if not match or match.group(1) in values:
                fail("invalid profile entry in profiles/{}.conf".format(name))
            key = match.group(1)
            if not (key.startswith("ENABLE_") or key.startswith("INSTALL_")):
                fail("unsupported profile key: {}".format(key))
            values[key] = match.group(2) == "true"
        profiles[name] = values
    key_sets = {frozenset(values) for values in profiles.values()}
    if len(key_sets) != 1:
        fail("profile key sets differ")
    known = set(required_flags)
    known.update(
        {
            "ENABLE_NEW_INIT",
            "ENABLE_CODEX_PLUGIN",
            "ENABLE_GHOSTTY_SETUP",
            "ENABLE_FONTS_SETUP",
            "INSTALL_AGENTS",
            "INSTALL_RULES",
            "INSTALL_COMMANDS",
            "INSTALL_SKILLS",
        }
    )
    if set(profiles[selected]) != known:
        fail("profile contains unknown keys or is missing required keys")
    return dict(profiles[selected]), set(profiles[selected])


def apply_overrides(values, allowed_keys, overrides):
    values["ENABLE_AUTO_UPDATE"] = False
    values["ENABLE_WEB_CONTENT_UPDATE"] = False
    values["ENABLE_CODEX_PLUGIN"] = False
    values["ENABLE_GHOSTTY_SETUP"] = False
    values["ENABLE_FONTS_SETUP"] = False
    values["COMMIT_ATTRIBUTION"] = False
    allowed = set(allowed_keys)
    allowed.add("COMMIT_ATTRIBUTION")
    seen = set()
    for item in overrides:
        match = re.fullmatch(r"([A-Z][A-Z0-9_]*)=(true|false)", item)
        if not match:
            fail("invalid override: {!r}".format(item))
        key, raw = match.groups()
        if key not in allowed or key in seen:
            fail("unknown or duplicate override: {}".format(key))
        if key in (
            "ENABLE_AUTO_UPDATE",
            "ENABLE_WEB_CONTENT_UPDATE",
            "ENABLE_CODEX_PLUGIN",
        ) and raw == "true":
            fail("self-mutating MDM component cannot be enabled: {}".format(key))
        values[key] = raw == "true"
        seen.add(key)
    if values["ENABLE_BIOME_HOOKS"] and values["ENABLE_PRETTIER_HOOKS"]:
        values["ENABLE_PRETTIER_HOOKS"] = False
    return values


def reject_duplicate_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            fail("duplicate JSON key: {}".format(key))
        result[key] = value
    return result


def parse_json(checkout, relative):
    text, _ = checkout.read_text(relative)

    def invalid_constant(value):
        fail("invalid JSON numeric value in {}: {}".format(relative, value))

    def invalid_float(value):
        fail("floating-point JSON is unsupported in {}: {}".format(relative, value))

    def safe_integer(value):
        result = int(value, 10)
        if abs(result) > 2**53 - 1:
            fail("JSON integer exceeds exact range in {}".format(relative))
        return result

    try:
        value = json.loads(
            text,
            object_pairs_hook=reject_duplicate_pairs,
            parse_constant=invalid_constant,
            parse_float=invalid_float,
            parse_int=safe_integer,
        )
    except RenderError:
        raise
    except (TypeError, ValueError, json.JSONDecodeError) as error:
        fail("invalid JSON in {}: {}".format(relative, error))
    if not isinstance(value, dict):
        fail("JSON root must be an object: {}".format(relative))
    return value


def merge_objects(left, right, concatenate_arrays=False):
    result = copy.deepcopy(left)
    for key, value in right.items():
        if key in result and isinstance(result[key], dict) and isinstance(value, dict):
            result[key] = merge_objects(result[key], value, concatenate_arrays)
        elif (
            concatenate_arrays
            and key in result
            and isinstance(result[key], list)
            and isinstance(value, list)
        ):
            result[key] = copy.deepcopy(result[key]) + copy.deepcopy(value)
        else:
            result[key] = copy.deepcopy(value)
    return result


def replace_home(value, logical_home):
    if isinstance(value, str):
        return value.replace("__HOME__", logical_home)
    if isinstance(value, list):
        return [replace_home(item, logical_home) for item in value]
    if isinstance(value, dict):
        return {key: replace_home(item, logical_home) for key, item in value.items()}
    return value


def render_settings(checkout, values, language, logical_home, flags, order):
    settings = merge_objects(
        parse_json(checkout, "config/settings-base.json"),
        parse_json(checkout, "config/permissions.json"),
    )
    for feature in order:
        flag = flags[feature]
        if not values[flag]:
            continue
        if feature == "web-content-update" and not values["INSTALL_SKILLS"]:
            continue
        suffix = ".legacy.json" if feature in ("auto-update", "pr-creation-log") else ".json"
        fragment = parse_json(checkout, "features/{}/hooks{}".format(feature, suffix))
        settings = merge_objects(settings, fragment, concatenate_arrays=True)
    settings["language"] = language
    environment = settings.get("env")
    if environment is None:
        environment = {}
        settings["env"] = environment
    if not isinstance(environment, dict):
        fail("settings env must be an object")
    environment["CLAUDE_CODE_NEW_INIT"] = "true" if values["ENABLE_NEW_INIT"] else "false"
    if values["COMMIT_ATTRIBUTION"]:
        settings.pop("attribution", None)
    else:
        settings["attribution"] = {"commit": "", "pr": ""}
    settings = replace_home(settings, logical_home)
    try:
        return (json.dumps(settings, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    except (TypeError, ValueError) as error:
        fail("cannot serialize settings: {}".format(error))


def render_claude(checkout, values, language):
    base, _ = checkout.read_text("i18n/{}/CLAUDE.md.base".format(language))
    partials = []
    if values["INSTALL_COMMANDS"]:
        partials.append(
            ("spec-kit", "i18n/{}/partials/spec-kit.md".format(language))
        )
    if values["INSTALL_SKILLS"]:
        partials.append(
            (
                "web-content-extraction",
                "i18n/{}/partials/web-content-extraction.md".format(language),
            )
        )
    if values["ENABLE_CODEX_PLUGIN"]:
        partials.append(
            ("codex-plugin", "features/codex-plugin/CLAUDE.md.partial.{}".format(language))
        )
    content = base
    for feature, relative in partials:
        marker = "{{FEATURE:" + feature + "}}"
        if marker not in content:
            fail("missing CLAUDE.md feature marker: {}".format(feature))
        partial, _ = checkout.read_text(relative)
        content = content.rstrip("\n").replace(marker, partial.rstrip("\n")) + "\n"
    unresolved = re.compile(r"{{[^}]*}}")
    content = "\n".join(
        line for line in content.split("\n") if not unresolved.search(line)
    )
    lines = content.split("\n")
    begin = [index for index, line in enumerate(lines) if line == BEGIN_MARKER]
    end = [index for index, line in enumerate(lines) if line == END_MARKER]
    if len(begin) != 1 or len(end) != 1 or begin[0] >= end[0]:
        fail("CLAUDE.md must contain exactly one valid managed marker pair")
    return ("\n".join(lines[begin[0] : end[0] + 1]) + "\n").encode("utf-8")


class ManagedTree:
    def __init__(self):
        self.files = {}
        self.collisions = {}
        self.total = 0

    def add(self, relative, data, mode, comparison="exact"):
        validate_relative(relative)
        if not isinstance(data, bytes):
            fail("internal non-byte managed file")
        collision_key = unicodedata.normalize("NFC", relative).casefold()
        if relative in self.files or collision_key in self.collisions:
            fail("duplicate or case-colliding managed path: {}".format(relative))
        if mode not in (GENERATED_MODE, EXECUTABLE_MODE):
            fail("invalid managed mode")
        if len(data) > MAX_FILE_BYTES:
            fail("rendered managed file exceeds size limit: {}".format(relative))
        if len(self.files) >= MAX_FILES or self.total + len(data) > MAX_TOTAL_BYTES:
            fail("rendered managed tree exceeds limits")
        self.files[relative] = {
            "data": data,
            "mode": mode,
            "comparison": comparison,
        }
        self.collisions[collision_key] = relative
        self.total += len(data)


def build_tree(checkout, values, language, logical_home, flags, order, script_features):
    tree = ManagedTree()
    tree.add(
        "settings.json",
        render_settings(checkout, values, language, logical_home, flags, order),
        GENERATED_MODE,
    )
    tree.add(
        "CLAUDE.md",
        render_claude(checkout, values, language),
        GENERATED_MODE,
        comparison="managed-section",
    )
    distributions = (
        ("INSTALL_AGENTS", "agents"),
        ("INSTALL_RULES", "rules"),
        ("INSTALL_COMMANDS", "commands"),
        ("INSTALL_SKILLS", "skills"),
    )
    for flag, source in distributions:
        if not values[flag]:
            continue
        for relative, data, source_mode in checkout.tree(source):
            mode = EXECUTABLE_MODE if source_mode & stat.S_IXUSR else GENERATED_MODE
            tree.add(source + "/" + relative, data, mode)
    for feature in order:
        if feature not in script_features or not values[flags[feature]]:
            continue
        source = "features/{}/scripts".format(feature)
        for relative, data, source_mode in checkout.tree(source):
            executable = relative.endswith((".sh", ".py")) or bool(
                source_mode & stat.S_IXUSR
            )
            mode = EXECUTABLE_MODE if executable else GENERATED_MODE
            tree.add("hooks/{}/{}".format(feature, relative), data, mode)
    return tree


def build_managed_universe(checkout, order, script_features):
    """Enumerate every checkout-shipped path, independent of selected profile."""
    paths = set()
    collision_keys = set()

    def add(relative):
        validate_relative(relative)
        collision = unicodedata.normalize("NFC", relative).casefold()
        if relative in paths or collision in collision_keys:
            fail("duplicate or case-colliding universe path: {}".format(relative))
        paths.add(relative)
        collision_keys.add(collision)

    for source in ("agents", "rules", "commands", "skills"):
        for relative, _data, _mode in checkout.tree(source):
            add(source + "/" + relative)
    for feature in order:
        if feature not in script_features:
            continue
        source = "features/{}/scripts".format(feature)
        for relative, _data, _mode in checkout.tree(source):
            add("hooks/{}/{}".format(feature, relative))
    return paths


def verify_output_parent(output):
    if not os.path.isabs(output) or has_control(output):
        fail("output must be an absolute path")
    normalized = os.path.normpath(output)
    if normalized != output:
        fail("output path must already be normalized")
    output = normalized
    if output == "/" or os.path.lexists(output):
        fail("output must be a nonexistent non-root path")
    parent = os.path.dirname(output)
    try:
        info = os.lstat(parent)
    except OSError as error:
        fail("cannot inspect output parent: {}".format(error))
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        fail("output parent is not a real directory")
    if info.st_uid != os.geteuid() or not mode_is_safe(info.st_mode):
        fail("output parent is not private to the effective user")
    return output


def write_exclusive(path, data, mode):
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    flags |= getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags, mode)
    try:
        view = memoryview(data)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                fail("short write to output")
            view = view[written:]
        os.fchmod(descriptor, mode)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def write_output(output, tree, universe, profile, language, logical_home):
    os.mkdir(output, 0o700)
    root_info = os.lstat(output)
    identity = (root_info.st_dev, root_info.st_ino)
    try:
        tree_root = os.path.join(output, "tree")
        os.mkdir(tree_root, 0o700)
        paths = sorted(tree.files)
        entries = []
        for relative in paths:
            record = tree.files[relative]
            parent = tree_root
            parts = relative.split("/")
            for component in parts[:-1]:
                parent = os.path.join(parent, component)
                if not os.path.exists(parent):
                    os.mkdir(parent, 0o700)
            destination = os.path.join(tree_root, *parts)
            write_exclusive(destination, record["data"], record["mode"])
            entries.append(
                {
                    "path": relative,
                    "live_mode": "{:04o}".format(record["mode"]),
                    "snapshot_mode": "{:04o}".format(record["mode"]),
                    "comparison": record["comparison"],
                    "size": len(record["data"]),
                    "sha256": hashlib.sha256(record["data"]).hexdigest(),
                }
            )
        modes = "".join(
            "{}\t{}\t{}\n".format(
                entry["path"], entry["live_mode"], entry["snapshot_mode"]
            )
            for entry in entries
        ).encode("utf-8")
        manifest = {
            "schema_version": 1,
            "profile": profile,
            "language": language,
            "logical_home": logical_home,
            "async_hooks": False,
            "files": paths,
            "absent_files": sorted(universe.difference(paths)),
            "entries": entries,
            "total_bytes": tree.total,
        }
        manifest_data = (json.dumps(manifest, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
        write_exclusive(os.path.join(output, "modes.tsv"), modes, GENERATED_MODE)
        write_exclusive(os.path.join(output, "manifest.json"), manifest_data, GENERATED_MODE)
        os.chmod(tree_root, 0o700)
        os.chmod(output, 0o700)
    except Exception:
        current = os.lstat(output)
        if (current.st_dev, current.st_ino) == identity and stat.S_ISDIR(current.st_mode):
            shutil.rmtree(output)
        raise
    return identity


def parse_arguments(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkout", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--profile", choices=PROFILE_NAMES, required=True)
    parser.add_argument("--language", choices=("en", "ja"), required=True)
    parser.add_argument("--logical-home", required=True)
    parser.add_argument("--override", action="append", default=[])
    parser.add_argument("--prior-managed", action="append", default=[])
    arguments = parser.parse_args(argv)
    if not os.path.isabs(arguments.logical_home):
        parser.error("--logical-home must be absolute")
    if os.path.normpath(arguments.logical_home) != arguments.logical_home:
        parser.error("--logical-home must already be normalized")
    if has_control(arguments.logical_home):
        parser.error("--logical-home contains a control character")
    if len(arguments.prior_managed) > MAX_INVENTORY_PATHS:
        parser.error("too many prior managed paths")
    prior = set()
    for relative in arguments.prior_managed:
        try:
            validate_relative(relative)
        except RenderError as error:
            parser.error(str(error))
        collision = unicodedata.normalize("NFC", relative).casefold()
        if collision in prior:
            parser.error("duplicate prior managed path")
        prior.add(collision)
    return arguments


def main(argv=None):
    arguments = parse_arguments(argv)
    output = None
    output_identity = None
    try:
        output = verify_output_parent(arguments.output)
        checkout = Checkout(arguments.checkout)
        flags, order, script_features = parse_registry(checkout)
        values, _ = parse_profile(checkout, arguments.profile, flags.values())
        output_affecting_overrides = set(flags.values())
        output_affecting_overrides.update({"ENABLE_NEW_INIT", "ENABLE_CODEX_PLUGIN"})
        values = apply_overrides(values, output_affecting_overrides, arguments.override)
        universe = build_managed_universe(checkout, order, script_features)
        universe_collisions = {
            unicodedata.normalize("NFC", relative).casefold(): relative
            for relative in universe
        }
        for relative in arguments.prior_managed:
            collision = unicodedata.normalize("NFC", relative).casefold()
            if collision in universe_collisions and universe_collisions[collision] != relative:
                fail("prior managed path case-collides with checkout: {}".format(relative))
            universe_collisions[collision] = relative
        universe.update(arguments.prior_managed)
        managed = build_tree(
            checkout,
            values,
            arguments.language,
            arguments.logical_home,
            flags,
            order,
            script_features,
        )
        output_identity = write_output(
            output,
            managed,
            universe,
            arguments.profile,
            arguments.language,
            arguments.logical_home,
        )
    except RenderError as error:
        if output and output_identity and os.path.isdir(output) and not os.path.islink(output):
            current = os.lstat(output)
            if (current.st_dev, current.st_ino) == output_identity:
                shutil.rmtree(output)
        print("render-expected: {}".format(error), file=sys.stderr)
        return 1
    except OSError as error:
        if output and output_identity and os.path.isdir(output) and not os.path.islink(output):
            current = os.lstat(output)
            if (current.st_dev, current.st_ino) == output_identity:
                shutil.rmtree(output)
        print("render-expected: output error: {}".format(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    os.umask(0o077)
    sys.exit(main())
