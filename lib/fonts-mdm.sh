#!/bin/bash
# lib/fonts-mdm.sh - Trusted MDM programming-font installation
#
# Requires: lib/fonts.sh (_font_zip_has_magic),
#           lib/prerequisites.sh (_register_tmp)
# Exports: fonts_mdm_are_trusted(), install_fonts_mdm()
set -euo pipefail

# MDM installs deliberately ignore the overridable non-MDM URLs above. These
# values pin the exact official GitHub release assets inspected on 2026-07-18.
MDM_IBM_PLEX_MONO_ZIP_URL="https://github.com/IBM/plex/releases/download/%40ibm/plex-mono%401.1.0/ibm-plex-mono.zip"
MDM_IBM_PLEX_MONO_ZIP_SHA256="4bfc936d0e1fd19db6327a3786eabdbc3dc0d464500576f6458f6706df68d26c"
MDM_IBM_PLEX_MONO_ZIP_SIZE="7307192"
MDM_HACKGEN_NF_ZIP_URL="https://github.com/yuru7/HackGen/releases/download/v2.10.0/HackGen_NF_v2.10.0.zip"
MDM_HACKGEN_NF_ZIP_SHA256="f8abd483d5edfad88a78ed511978f43c83b43c48e364aa29ebe4a68217474428"
MDM_HACKGEN_NF_ZIP_SIZE="25120250"
_fonts_mdm_managed() {
  case "$(printf '%s' "${KIT_MDM_MANAGED:-}" | /usr/bin/tr '[:upper:]' '[:lower:]')" in
    true|1|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

_font_mdm_mode() {
  case "${KIT_MDM_PREREQ_MODE:-auto}" in
    auto|fail) printf '%s' "${KIT_MDM_PREREQ_MODE:-auto}" ;;
    *) return 1 ;;
  esac
}

_font_mdm_expected_inventory() {
  case "$1" in
    ibm)
      printf '%s\n' \
        'IBMPlexMono-Bold.ttf ca403c56931baef307d20ba64b69acb71abcad61f75e66414661d57484b690ec' \
        'IBMPlexMono-BoldItalic.ttf 0e45a5a540992163229d2a29662553f313fab391757ca2ab3dc8f4e0d9be0979' \
        'IBMPlexMono-ExtraLight.ttf 9c84b764bfc85441f53ce5d261c369156b0612a02837f1483ae525916c846486' \
        'IBMPlexMono-ExtraLightItalic.ttf 2c168787c187535d0d42e2150e10841887e0f94bddc0ebd0ee936520621ca854' \
        'IBMPlexMono-Italic.ttf 8ebe04c8c6cc82f0be19896ddc61d9935cdd0f027b0173c1945b8d247d7dfc2a' \
        'IBMPlexMono-Light.ttf f2a7e41a2bb183a1ba82b415eb176ac2dd81d2ca9fc8d2a2c23e5d413b89540e' \
        'IBMPlexMono-LightItalic.ttf 14c3e18514d64a95b82cacf8a6d77a173fadff92c90aed9905faf9a71fa83876' \
        'IBMPlexMono-Medium.ttf 0bede3debdea8488bbb927f8f0650d915073209734a67fe8cd5a3320b572511c' \
        'IBMPlexMono-MediumItalic.ttf 71bd1f5f16fa0d10b101e050c67db3a2276f274e59cccfb3e9f9af3fc007a5a3' \
        'IBMPlexMono-Regular.ttf fe11304a5fe956d5744e9b6a246cc83d90425245e75a62230044966ca96a7f50' \
        'IBMPlexMono-SemiBold.ttf c9417148ce13f8fa7d2d5c9180bbc141f72aa0d814ffeb280f6904dc2b1bbd7a' \
        'IBMPlexMono-SemiBoldItalic.ttf 7b4b32e3b8beb4fda5605a619671e61c27efc98f64fdc078ce225556f40aa8c5' \
        'IBMPlexMono-Text.ttf 650b37d83353821b19000dc8db573e27290aa82bb3b5e7366613eaa7260ca0fe' \
        'IBMPlexMono-TextItalic.ttf fd037a88a0f0b29b95db086ee50450a69ac3a7cbb752ed286fca23d65711bc9c' \
        'IBMPlexMono-Thin.ttf 34ce19c385afdd31726866c4797314f78ae59de41da04e898e4b3a04fc709ecd' \
        'IBMPlexMono-ThinItalic.ttf 059d9f9bdd35a26bbdfd8e68ccc18a4a5fe4f9af22cbc80509206936583f122c'
      ;;
    hackgen)
      printf '%s\n' \
        'HackGen35ConsoleNF-Bold.ttf ba3f1d6f97961d18cedc565f6a7399d1d0fd115e0d9d2f251f5d8d6ac6453f1c' \
        'HackGen35ConsoleNF-Regular.ttf 83c32fe20da5e5a8fd3c5624db872811282b6380774436b2011bfc42bba149c1' \
        'HackGenConsoleNF-Bold.ttf 43b554e7ffccca4c1587d34ec139605bd3fa4b4843446bfb3334ab95cfb44e53' \
        'HackGenConsoleNF-Regular.ttf 6c2d654cceb7ad2164d23e068bbae69647295413432ecfc970400b401d6f9873'
      ;;
    *) return 1 ;;
  esac
}

_font_mdm_expected_names() {
  local name hash
  while read -r name hash; do
    [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "$name"
  done < <(_font_mdm_expected_inventory "$1")
}

_font_mdm_expected_sha256() {
  local family="$1" wanted="$2" name hash
  while read -r name hash; do
    if [[ "$name" == "$wanted" && "$hash" =~ ^[0-9a-f]{64}$ ]]; then
      printf '%s' "$hash"
      return 0
    fi
  done < <(_font_mdm_expected_inventory "$family")
  return 1
}

_font_mdm_sha256_file() {
  local path="$1" output hash
  [[ -f "$path" && ! -L "$path" ]] || return 1
  if [[ -x /usr/bin/shasum ]]; then
    output="$(/usr/bin/shasum -a 256 "$path")" || return 1
  elif command -v sha256sum >/dev/null 2>&1; then
    output="$(sha256sum "$path")" || return 1
  else
    return 1
  fi
  hash="${output%%[[:space:]]*}"
  [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s' "$hash"
}

_font_mdm_archive_is_trusted() {
  local path="$1" expected_sha="$2" expected_size="$3" size actual_sha
  [[ "$expected_sha" =~ ^[0-9a-f]{64}$ \
    && "$expected_size" =~ ^[0-9]+$ ]] || return 1
  [[ -f "$path" && ! -L "$path" ]] || return 1
  size="$(LC_ALL=C /usr/bin/wc -c < "$path" | /usr/bin/tr -d '[:space:]')" \
    || return 1
  [[ "$size" == "$expected_size" && "$size" -le 33554432 ]] || return 1
  _font_zip_has_magic "$path" || return 1
  actual_sha="$(_font_mdm_sha256_file "$path")" || return 1
  [[ "$actual_sha" == "$expected_sha" ]]
}

_font_mdm_download() {
  /usr/bin/curl --fail --silent --show-error --location \
    --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --connect-timeout 30 --max-time 300 --output "$2" -- "$1"
}

# Inspect the complete zip inventory, reject unsafe entry types/paths and
# enforce compressed-output bounds before extracting only the expected TTFs.
_font_mdm_extract_archive() {
  local family="$1" archive="$2" destination="$3" prefix name
  local members=()
  case "$family" in
    ibm) prefix="ibm-plex-mono/fonts/complete/ttf" ;;
    hackgen) prefix="HackGen_NF_v2.10.0" ;;
    *) return 1 ;;
  esac
  while IFS= read -r name; do
    members+=("$prefix/$name")
  done < <(_font_mdm_expected_names "$family")
  [[ -x /usr/bin/python3 && -d "$destination" && ! -L "$destination" ]] \
    || return 1
  /usr/bin/python3 -I -B - "$archive" "$destination" "${members[@]}" <<'PY'
import os
import stat
import sys
import zipfile

archive, destination, *expected = sys.argv[1:]
MAX_ENTRIES = 512
MAX_MEMBER = 16 * 1024 * 1024
MAX_TOTAL = 64 * 1024 * 1024

try:
    expected_set = set(expected)
    if not expected or len(expected_set) != len(expected):
        raise ValueError("invalid expected inventory")
    with zipfile.ZipFile(archive) as source:
        entries = source.infolist()
        if not entries or len(entries) > MAX_ENTRIES:
            raise ValueError("invalid entry count")
        seen = set()
        total = 0
        selected = {}
        for entry in entries:
            name = entry.filename
            if (not name or name in seen or name.startswith(("/", "\\"))
                    or "\\" in name or any(ord(ch) < 32 or ord(ch) == 127 for ch in name)):
                raise ValueError("unsafe archive path")
            seen.add(name)
            parts = name.rstrip("/").split("/")
            if not parts or any(part in ("", ".", "..") for part in parts):
                raise ValueError("unsafe archive segment")
            mode = (entry.external_attr >> 16) & 0xFFFF
            kind = stat.S_IFMT(mode)
            if kind not in (0, stat.S_IFREG, stat.S_IFDIR):
                raise ValueError("unsafe archive entry type")
            if entry.flag_bits & 1:
                raise ValueError("encrypted archive entry")
            if entry.file_size < 0 or entry.file_size > MAX_MEMBER:
                raise ValueError("oversized archive member")
            total += entry.file_size
            if total > MAX_TOTAL:
                raise ValueError("oversized archive")
            if name in expected_set:
                if entry.is_dir():
                    raise ValueError("expected font is a directory")
                selected[name] = entry
        if set(selected) != expected_set:
            raise ValueError("font inventory mismatch")
        for member in expected:
            target = os.path.join(destination, os.path.basename(member))
            flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
            flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
            descriptor = os.open(target, flags, 0o600)
            copied = 0
            try:
                with source.open(selected[member], "r") as content:
                    while True:
                        block = content.read(1024 * 1024)
                        if not block:
                            break
                        copied += len(block)
                        if copied > MAX_MEMBER:
                            raise ValueError("font expanded beyond bound")
                        os.write(descriptor, block)
                if copied != selected[member].file_size:
                    raise ValueError("font size mismatch")
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
except (OSError, ValueError, zipfile.BadZipFile, zipfile.LargeZipFile):
    sys.exit(1)
PY
}

# Validate a bounded, race-bound sfnt/TrueType file and its internal naming.
# The optional logical name is used for a same-directory temporary replacement.
_font_mdm_ttf_structure_is_valid() {
  local path="$1" family="$2" logical_name="${3:-${1##*/}}"
  case "$family" in ibm|hackgen) : ;; *) return 1 ;; esac
  [[ -x /usr/bin/python3 && -f "$path" && ! -L "$path" ]] || return 1
  /usr/bin/python3 -I -B - "$path" "$family" "$logical_name" <<'PY' \
    || return 1
import os
import stat
import struct
import sys

path, family, logical_name = sys.argv[1:]
IBM_NAMES = {
    "IBMPlexMono-Bold.ttf", "IBMPlexMono-BoldItalic.ttf",
    "IBMPlexMono-ExtraLight.ttf", "IBMPlexMono-ExtraLightItalic.ttf",
    "IBMPlexMono-Italic.ttf", "IBMPlexMono-Light.ttf",
    "IBMPlexMono-LightItalic.ttf", "IBMPlexMono-Medium.ttf",
    "IBMPlexMono-MediumItalic.ttf", "IBMPlexMono-Regular.ttf",
    "IBMPlexMono-SemiBold.ttf", "IBMPlexMono-SemiBoldItalic.ttf",
    "IBMPlexMono-Text.ttf", "IBMPlexMono-TextItalic.ttf",
    "IBMPlexMono-Thin.ttf", "IBMPlexMono-ThinItalic.ttf",
}
HACK_NAMES = {
    "HackGen35ConsoleNF-Bold.ttf", "HackGen35ConsoleNF-Regular.ttf",
    "HackGenConsoleNF-Bold.ttf", "HackGenConsoleNF-Regular.ttf",
}

def identity(value):
    return (value.st_dev, value.st_ino, value.st_mode, value.st_uid,
            value.st_gid, value.st_size, value.st_mtime_ns)

try:
    allowed = IBM_NAMES if family == "ibm" else HACK_NAMES
    if logical_name not in allowed:
        raise ValueError("unexpected font name")
    before = os.lstat(path)
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        opened = os.fstat(descriptor)
        if (not stat.S_ISREG(opened.st_mode) or identity(opened) != identity(before)
                or opened.st_size < 256 or opened.st_size > 16 * 1024 * 1024):
            raise ValueError("unsafe font file")
        chunks = []
        remaining = opened.st_size
        while remaining:
            block = os.read(descriptor, min(1024 * 1024, remaining))
            if not block:
                raise ValueError("short font read")
            chunks.append(block)
            remaining -= len(block)
        data = b"".join(chunks)
    finally:
        os.close(descriptor)
    if identity(os.lstat(path)) != identity(before):
        raise ValueError("font changed during validation")
    if data[:4] != b"\x00\x01\x00\x00":
        raise ValueError("not TrueType sfnt")
    table_count = struct.unpack_from(">H", data, 4)[0]
    directory_end = 12 + table_count * 16
    if table_count < 8 or table_count > 256 or directory_end > len(data):
        raise ValueError("invalid sfnt directory")
    tables = {}
    for index in range(table_count):
        offset = 12 + index * 16
        tag, _checksum, table_offset, table_length = struct.unpack_from(">4sIII", data, offset)
        if (tag in tables or table_offset < directory_end or table_length == 0
                or table_offset + table_length > len(data)):
            raise ValueError("invalid sfnt table")
        tables[tag] = (table_offset, table_length)
    required = {b"cmap", b"glyf", b"head", b"hhea", b"hmtx", b"loca", b"maxp", b"name"}
    if not required.issubset(tables):
        raise ValueError("missing sfnt table")
    head_offset, head_length = tables[b"head"]
    if head_length < 54 or data[head_offset + 12:head_offset + 16] != b"_\x0f<\xf5":
        raise ValueError("invalid head table")
    name_offset, name_length = tables[b"name"]
    if name_length < 6:
        raise ValueError("invalid name table")
    name_format, record_count, strings_offset = struct.unpack_from(">HHH", data, name_offset)
    records_end = 6 + record_count * 12
    if name_format not in (0, 1) or not 1 <= record_count <= 4096:
        raise ValueError("invalid name records")
    if records_end > name_length or strings_offset < records_end or strings_offset > name_length:
        raise ValueError("invalid name storage")
    names = {1: set(), 5: set(), 6: set()}
    for index in range(record_count):
        record = name_offset + 6 + index * 12
        platform, _encoding, _language, name_id, length, relative = struct.unpack_from(">HHHHHH", data, record)
        if name_id not in names:
            continue
        start = name_offset + strings_offset + relative
        end = start + length
        if start < name_offset or end > name_offset + name_length:
            raise ValueError("invalid name string")
        codec = "utf-16-be" if platform in (0, 3) else "mac_roman"
        try:
            value = data[start:end].decode(codec)
        except UnicodeError:
            continue
        if value:
            names[name_id].add(value)
    if not all(names.values()):
        raise ValueError("missing internal font names")
    if family == "ibm":
        if (not any(value.startswith("IBM Plex Mono") for value in names[1])
                or "Version 2.004" not in names[5]
                or not any(value.startswith("IBMPlexMono") for value in names[6])):
            raise ValueError("IBM font identity mismatch")
    else:
        expected_family = "HackGen35 Console NF" if logical_name.startswith("HackGen35") else "HackGen Console NF"
        expected_postscript = logical_name[:-4]
        if (expected_family not in names[1]
                or not any(value.startswith("Version 2.10.0") for value in names[5])
                or expected_postscript not in names[6]):
            raise ValueError("HackGen font identity mismatch")
except (OSError, ValueError, struct.error):
    sys.exit(1)
PY
}

_font_mdm_ttf_is_trusted() {
  local path="$1" family="$2" logical_name="${3:-${1##*/}}"
  local expected_sha actual_sha
  _font_mdm_ttf_structure_is_valid "$path" "$family" "$logical_name" \
    || return 1
  expected_sha="$(_font_mdm_expected_sha256 "$family" "$logical_name")" \
    || return 1
  actual_sha="$(_font_mdm_sha256_file "$path")" || return 1
  [[ "$actual_sha" == "$expected_sha" ]]
}

_font_mdm_family_is_trusted() {
  local family="$1" font_dir="$2" name target count=0
  [[ -d "$font_dir" && ! -L "$font_dir" ]] || return 1
  while IFS= read -r name; do
    target="$font_dir/$name"
    [[ -f "$target" && ! -L "$target" ]] || return 1
    _font_mdm_ttf_is_trusted "$target" "$family" "$name" || return 1
    count=$((count + 1))
  done < <(_font_mdm_expected_names "$family")
  [[ "$count" -gt 0 ]]
}

fonts_mdm_are_trusted() {
  local font_dir="${1:-$HOME/Library/Fonts}"
  _font_mdm_family_is_trusted ibm "$font_dir" \
    && _font_mdm_family_is_trusted hackgen "$font_dir"
}

_font_mdm_prepare_target_dir() {
  local font_dir="$1" parent="${1%/*}"
  [[ "$font_dir" == /* && ! "$font_dir" =~ [[:cntrl:]] ]] || return 1
  [[ -d "$HOME" && ! -L "$HOME" ]] || return 1
  [[ -d "$parent" && ! -L "$parent" ]] || return 1
  if [[ -e "$font_dir" || -L "$font_dir" ]]; then
    [[ -d "$font_dir" && ! -L "$font_dir" ]] || return 1
  else
    /bin/mkdir "$font_dir" || return 1
  fi
}

_font_mdm_replace_family() {
  local family="$1" staged="$2" font_dir="$3" name source target temporary
  local index prepared=() targets=()
  while IFS= read -r name; do
    source="$staged/$name"
    target="$font_dir/$name"
    _font_mdm_ttf_is_trusted "$source" "$family" "$name" || return 1
    if [[ -e "$target" || -L "$target" ]]; then
      [[ -f "$target" || -L "$target" ]] || return 1
    fi
    temporary="$(/usr/bin/mktemp "$font_dir/.claude-starter-kit-font.XXXXXX")" \
      || return 1
    if ! /bin/cp -f "$source" "$temporary" \
      || ! /bin/chmod 0644 "$temporary" \
      || ! _font_mdm_ttf_is_trusted "$temporary" "$family" "$name"; then
      /bin/rm -f -- "$temporary"
      for temporary in "${prepared[@]+"${prepared[@]}"}"; do
        [[ -z "$temporary" ]] || /bin/rm -f -- "$temporary"
      done
      return 1
    fi
    prepared+=("$temporary")
    targets+=("$target")
  done < <(_font_mdm_expected_names "$family")
  for ((index = 0; index < ${#prepared[@]}; index++)); do
    if ! /bin/mv -f -h "${prepared[$index]}" "${targets[$index]}"; then
      for temporary in "${prepared[@]:$index}"; do
        [[ -z "$temporary" ]] || /bin/rm -f -- "$temporary"
      done
      return 1
    fi
    prepared[$index]=""
  done
}

_font_mdm_install_family_auto() {
  local family="$1" font_dir="$2" workspace="$3"
  local url sha size archive staged
  case "$family" in
    ibm)
      url="$MDM_IBM_PLEX_MONO_ZIP_URL"
      sha="$MDM_IBM_PLEX_MONO_ZIP_SHA256"
      size="$MDM_IBM_PLEX_MONO_ZIP_SIZE"
      ;;
    hackgen)
      url="$MDM_HACKGEN_NF_ZIP_URL"
      sha="$MDM_HACKGEN_NF_ZIP_SHA256"
      size="$MDM_HACKGEN_NF_ZIP_SIZE"
      ;;
    *) return 1 ;;
  esac
  archive="$workspace/$family.zip"
  staged="$workspace/$family-fonts"
  /bin/mkdir "$staged" || return 1
  _font_mdm_download "$url" "$archive" || return 1
  _font_mdm_archive_is_trusted "$archive" "$sha" "$size" || return 1
  _font_mdm_extract_archive "$family" "$archive" "$staged" || return 1
  _font_mdm_replace_family "$family" "$staged" "$font_dir" || return 1
  _font_mdm_family_is_trusted "$family" "$font_dir"
}

_font_mdm_workspace() {
  local output_var="$1" created
  [[ "$output_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ \
    && "$(type -t _register_tmp)" == function ]] || return 1
  created="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/claude-kit-mdm-fonts.XXXXXX")" \
    || return 1
  /bin/chmod 700 "$created" || return 1
  _register_tmp "$created"
  printf -v "$output_var" '%s' "$created"
}

_font_mdm_install_or_validate_family() {
  local family="$1" font_dir="${2:-$HOME/Library/Fonts}" mode workspace
  [[ "$(/usr/bin/uname -s)" == "Darwin" ]] || return 1
  mode="$(_font_mdm_mode)" || return 1
  if [[ "$mode" == "fail" ]]; then
    _font_mdm_family_is_trusted "$family" "$font_dir"
    return
  fi
  _font_mdm_prepare_target_dir "$font_dir" || return 1
  _font_mdm_workspace workspace || return 1
  _font_mdm_install_family_auto "$family" "$font_dir" "$workspace"
}

install_fonts_mdm() {
  local font_dir="${1:-$HOME/Library/Fonts}" mode workspace
  [[ "$(/usr/bin/uname -s)" == "Darwin" ]] || return 1
  mode="$(_font_mdm_mode)" || return 1
  if [[ "$mode" == "fail" ]]; then
    fonts_mdm_are_trusted "$font_dir"
    return
  fi
  _font_mdm_prepare_target_dir "$font_dir" || return 1
  _font_mdm_workspace workspace || return 1
  _font_mdm_install_family_auto ibm "$font_dir" "$workspace" || return 1
  _font_mdm_install_family_auto hackgen "$font_dir" "$workspace" || return 1
  fonts_mdm_are_trusted "$font_dir"
}
