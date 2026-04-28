#!/usr/bin/env python3
"""
preflight-introspect.py — Xcode projesinin yapısını çıkarır.

Hibrit yaklaşım:
  - xcodebuild ile config-spesifik build settings (macros, INFOPLIST_FILE,
    deployment target, bundle id, excluded files) — Apple'ın resmi tool'u, %100 doğru.
  - pbxproj parse ile target → kaynak klasör/dosya listesi — hızlı.

Cache: scripts/.preflight-project.json (pbxproj + tüm xcconfig'lerin mtime
hash'i ile invalide edilir).

Kullanım:
  python3 preflight-introspect.py            # cache varsa kullan
  python3 preflight-introspect.py --no-cache # zorla yenile
  python3 preflight-introspect.py --print-cmd # parse'a girmeden xcodebuild komutlarını yazdır
"""
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
# Brew install ile script libexec/'te yaşar. Repo kökü = caller'ın CWD'si.
REPO_ROOT = Path(os.environ.get("PREFLIGHT_REPO_ROOT") or os.getcwd()).resolve()
CACHE_DIR = REPO_ROOT / ".preflight"
CACHE_DIR.mkdir(parents=True, exist_ok=True)
CACHE_PATH = CACHE_DIR / "project.json"


# ─── pbxproj mini-parser ───────────────────────────────────────────────
# pbxproj NextStep ASCII plist formatıdır. Tam parser yerine targeted
# regex'lerle ihtiyaç duyduğumuz blokları çıkarıyoruz.

UUID_RE = r"[A-F0-9]{24}"


def _find_isa_blocks(text, isa_type):
    """isa = X; içeren blokları brace-balance ile bulur. (uuid, comment, body) listesi.
    Regex back-tracking sorunlarına karşı güvenli; tek başına string scanner."""
    results = []
    marker = f"isa = {isa_type};"
    header_re = re.compile(rf"({UUID_RE}) /\* (.+?) \*/ = \s*$")
    pos = 0
    while True:
        idx = text.find(marker, pos)
        if idx == -1:
            break
        # Geriye en yakın açılış brace'i bul
        brace_start = text.rfind("{", 0, idx)
        if brace_start < 0:
            pos = idx + len(marker)
            continue
        # Brace'in hemen öncesinde UUID + /* comment */ = formatını ara
        prefix = text[max(0, brace_start - 300):brace_start]
        m = header_re.search(prefix)
        if not m:
            pos = idx + len(marker)
            continue
        uuid, comment = m.group(1), m.group(2)
        # Eşleşen kapanış brace'ini bul (depth tracking)
        depth = 1
        i = brace_start + 1
        n = len(text)
        while i < n and depth > 0:
            c = text[i]
            if c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        body = text[brace_start + 1:i]
        results.append((uuid, comment, body))
        pos = i + 1
    return results


def _get_field(body, field):
    """`field = "value";` veya `field = value;` parse et."""
    m = re.search(rf"\b{re.escape(field)} = \"([^\"]*)\";", body)
    if m:
        return m.group(1)
    m = re.search(rf"\b{re.escape(field)} = ([^;\n]+);", body)
    return m.group(1).strip() if m else None


def _get_uuid_list(body, field):
    """`field = ( UUID, UUID, );` parse et."""
    m = re.search(rf"\b{re.escape(field)} = \(([^)]*)\);", body, re.DOTALL)
    if not m:
        return []
    return re.findall(UUID_RE, m.group(1))


def _get_string_list(body, field):
    """`field = ( "foo", "bar", );` parse et."""
    m = re.search(rf"\b{re.escape(field)} = \(([^)]*)\);", body, re.DOTALL)
    if not m:
        return []
    items = re.findall(r'(?:"([^"]+)"|([A-Za-z0-9_./-]+))', m.group(1))
    return [a or b for a, b in items if (a or b)]


def parse_pbxproj(pbx_text):
    """pbxproj'dan ihtiyacımız olan yapıları çıkar."""
    # Native targets
    targets = []
    for uuid, comment, body in _find_isa_blocks(pbx_text, "PBXNativeTarget"):
        targets.append({
            "uuid": uuid,
            "name": _get_field(body, "name") or comment,
            "productType": (_get_field(body, "productType") or "").strip('"'),
            "syncGroupUUIDs": _get_uuid_list(body, "fileSystemSynchronizedGroups"),
        })

    # Synchronized root groups (klasör adları)
    sync_groups = {}
    for uuid, comment, body in _find_isa_blocks(pbx_text, "PBXFileSystemSynchronizedRootGroup"):
        sync_groups[uuid] = {
            "name": comment,
            "path": _get_field(body, "path") or comment,
            "exceptionUUIDs": _get_uuid_list(body, "exceptions"),
        }

    # Exception set'ler — synchronized group içinde belirli dosyalar exclude
    exception_sets = {}
    for uuid, comment, body in _find_isa_blocks(
        pbx_text, "PBXFileSystemSynchronizedBuildFileExceptionSet"
    ):
        exception_sets[uuid] = {
            "membershipExceptions": _get_string_list(body, "membershipExceptions"),
            "target": _get_field(body, "target"),
        }

    return {
        "targets": targets,
        "syncGroups": sync_groups,
        "exceptionSets": exception_sets,
    }


# ─── xcodebuild ─────────────────────────────────────────────────────────

def find_xcodeproj(repo_root):
    """Repo kökündeki .xcodeproj'ı bul."""
    for p in sorted(repo_root.iterdir()):
        if p.is_dir() and p.suffix == ".xcodeproj":
            return p
    return None


def xcb(args, timeout=60):
    """xcodebuild yardımcı."""
    proc = subprocess.run(
        ["xcodebuild"] + args,
        capture_output=True, text=True, timeout=timeout,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"xcodebuild fail ({proc.returncode}):\n{proc.stderr[-500:]}"
        )
    return proc.stdout


def list_project(xcproj):
    """xcodebuild -list -json."""
    out = xcb(["-list", "-project", str(xcproj), "-json"], timeout=30)
    return json.loads(out)


def show_build_settings(xcproj, target, config):
    """xcodebuild -showBuildSettings -json — verilen target+config için."""
    out = xcb([
        "-showBuildSettings",
        "-project", str(xcproj),
        "-target", target,
        "-configuration", config,
        "-json",
    ], timeout=60)
    arr = json.loads(out)
    return arr[0]["buildSettings"] if arr else {}


def extract_macros(swift_conditions, gcc_defs):
    """SWIFT_ACTIVE_COMPILATION_CONDITIONS + GCC_PREPROCESSOR_DEFINITIONS'tan
    aktif macro setini çıkar. $(inherited) ve DEBUG=1 gibi formatları temizler."""
    macros = set()
    for tok in (swift_conditions or "").split():
        tok = tok.strip()
        if tok and not tok.startswith("$("):
            macros.add(tok)
    # GCC defs liste veya string olabilir
    if isinstance(gcc_defs, str):
        gcc_defs = gcc_defs.split()
    for d in gcc_defs or []:
        if "=" in d:
            d = d.split("=", 1)[0]
        d = d.strip()
        if d and not d.startswith("$("):
            macros.add(d)
    return sorted(macros)


# ─── Dosya listesi ──────────────────────────────────────────────────────

def list_swift_files(repo_root, sync_folder, exclusions):
    """sync_folder altındaki tüm .swift dosyalarını topla.
    exclusions = membershipException string listesi (relative path veya basename)."""
    base = repo_root / sync_folder
    if not base.exists():
        return []
    excl_set = {e.strip("/") for e in exclusions}
    out = []
    for p in base.rglob("*.swift"):
        rel = p.relative_to(repo_root)
        rel_str = str(rel)
        # exclusion check: full path (sync_folder içinde göreli) veya basename
        rel_to_sync = str(p.relative_to(base))
        if rel_to_sync in excl_set or p.name in excl_set:
            continue
        out.append(rel_str)
    return sorted(out)


# ─── Cache ──────────────────────────────────────────────────────────────

def project_signature(xcproj, repo_root):
    """pbxproj + tüm xcconfig'lerin mtime'larından bir hash üret."""
    h = hashlib.sha256()
    pbx = xcproj / "project.pbxproj"
    h.update(f"{pbx}:{pbx.stat().st_mtime}\n".encode())
    for xc in sorted(repo_root.rglob("*.xcconfig")):
        s = str(xc)
        if "/build/" in s or ".xcarchive" in s or "/.build/" in s:
            continue
        h.update(f"{xc}:{xc.stat().st_mtime}\n".encode())
    return h.hexdigest()


# ─── Main ───────────────────────────────────────────────────────────────

def introspect(no_cache=False):
    xcproj = find_xcodeproj(REPO_ROOT)
    if not xcproj:
        return {"error": "No .xcodeproj found in repo root"}

    sig = project_signature(xcproj, REPO_ROOT)

    # Cache hit?
    if not no_cache and CACHE_PATH.exists():
        try:
            cached = json.loads(CACHE_PATH.read_text(encoding="utf-8"))
            if cached.get("_signature") == sig:
                cached["_cacheHit"] = True
                return cached
        except (ValueError, OSError):
            pass

    # Fresh
    listing = list_project(xcproj)
    project_name = listing["project"]["name"]
    target_names = listing["project"]["targets"]
    config_names = listing["project"]["configurations"]

    pbx_text = (xcproj / "project.pbxproj").read_text(encoding="utf-8")
    pbx = parse_pbxproj(pbx_text)

    # name → target dict (pbx'tekiyle xcodebuild'inkini eşle)
    pbx_by_name = {t["name"]: t for t in pbx["targets"]}

    targets_out = []
    for tname in target_names:
        pbx_t = pbx_by_name.get(tname, {})
        sync_uuids = pbx_t.get("syncGroupUUIDs", [])

        # Sync klasör listesi
        sync_folders = []
        # her sync group için exception (target-spesifik) kontrol et
        per_group_exclusions = {}
        for guuid in sync_uuids:
            g = pbx["syncGroups"].get(guuid)
            if not g:
                continue
            sync_folders.append(g["path"])
            # bu group'un exception_set'lerini kontrol et — target'ımıza ait olanları al
            excl = []
            for euuid in g["exceptionUUIDs"]:
                eset = pbx["exceptionSets"].get(euuid)
                if not eset:
                    continue
                # exception set'in target field'ı bizim target'ın UUID'sine eşit mi?
                if eset.get("target") == pbx_t.get("uuid"):
                    excl.extend(eset.get("membershipExceptions", []))
            per_group_exclusions[g["path"]] = excl

        # Tüm sync klasörlerinden swift dosyalarını topla
        source_files = []
        for folder in sync_folders:
            source_files.extend(
                list_swift_files(REPO_ROOT, folder, per_group_exclusions.get(folder, []))
            )
        source_files = sorted(set(source_files))

        # Her config için xcodebuild -showBuildSettings
        configs_out = {}
        for cname in config_names:
            try:
                bs = show_build_settings(xcproj, tname, cname)
            except RuntimeError as e:
                configs_out[cname] = {"error": str(e)}
                continue

            macros = extract_macros(
                bs.get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", ""),
                bs.get("GCC_PREPROCESSOR_DEFINITIONS", ""),
            )
            excluded = bs.get("EXCLUDED_SOURCE_FILE_NAMES", "")
            excluded_list = [e for e in (excluded or "").split() if e and "$(" not in e]

            configs_out[cname] = {
                "macros": macros,
                "infoPlist": bs.get("INFOPLIST_FILE", ""),
                "deploymentTarget": bs.get("IPHONEOS_DEPLOYMENT_TARGET", ""),
                "bundleId": bs.get("PRODUCT_BUNDLE_IDENTIFIER", ""),
                "productName": bs.get("PRODUCT_NAME", ""),
                "configurationBuildDir": bs.get("CONFIGURATION_BUILD_DIR", ""),
                "excludedSourceFileNames": excluded_list,
                "marketingVersion": bs.get("MARKETING_VERSION", ""),
                "currentProjectVersion": bs.get("CURRENT_PROJECT_VERSION", ""),
            }

        targets_out.append({
            "name": tname,
            "productType": pbx_t.get("productType", ""),
            "syncFolders": sync_folders,
            "sourceFiles": source_files,
            "configs": configs_out,
        })

    # Default config — en yaygın isimleri kontrol ederek bul
    default_config = None
    m = re.search(r"defaultConfigurationName = ([^;]+);", pbx_text)
    if m:
        default_config = m.group(1).strip()

    result = {
        "_signature": sig,
        "_generatedAt": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "_cacheHit": False,
        "project": {
            "name": project_name,
            "path": str(xcproj.relative_to(REPO_ROOT)),
            "configurations": config_names,
            "defaultConfiguration": default_config,
        },
        "targets": targets_out,
    }

    # Cache yaz
    try:
        CACHE_PATH.write_text(
            json.dumps(result, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
    except OSError:
        pass

    return result


def main():
    no_cache = "--no-cache" in sys.argv
    try:
        result = introspect(no_cache=no_cache)
    except subprocess.TimeoutExpired:
        result = {"error": "xcodebuild timeout"}
    except Exception as e:
        result = {"error": f"{type(e).__name__}: {e}"}

    json.dump(result, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")
    sys.exit(0 if "error" not in result else 1)


if __name__ == "__main__":
    main()
