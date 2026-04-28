#!/usr/bin/env bash
# preflight-scan.sh — iOS Live Release Preflight Check
#
# iOS projelerinde live'a çıkmadan önce çalıştırılacak kod kalitesi &
# release-readiness denetim aracı.
#
# Kullanım:
#   preflight                          # standart denetim (mevcut dizin)
#   preflight --strict                 # WARN'lar da fail döner (CI)
#   preflight --report out.md          # markdown rapor üret
#   preflight --only print,todo        # sadece bazı kuralları çalıştır
#   preflight --skip ats,mock          # bazı kuralları atla
#   preflight --src "MyApp"            # kaynak klasör override
#
# Konfig: repo root'unda `.preflightignore` ile dosya yolları (substring match)
#         devre dışı bırakılabilir, satır başına bir kalıp.
#
# Çıkış kodu:
#   0  → temiz (veya sadece WARN var, --strict yok)
#   1  → ERROR var (veya --strict ile WARN var)
#   2  → script kullanım hatası

set -o pipefail
# macOS varsayılan bash 3.2 ile uyumlu — `declare -A` veya `set -u` kullanma.

# ─── Renkler ────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    R=$'\033[31m'; Y=$'\033[33m'; G=$'\033[32m'; B=$'\033[34m'
    BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'
else
    R=""; Y=""; G=""; B=""; BOLD=""; DIM=""; NC=""
fi

# ─── Argümanlar ─────────────────────────────────────────────────────────
STRICT=0
REPORT_FILE=""
JSON_FILE=""
ONLY=""
SKIP=""
SRC_DIR=""
TARGET_NAME=""
CONFIG_NAME=""

usage() {
    sed -n '2,18p' "$0"
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --strict)   STRICT=1; shift ;;
        --report)   REPORT_FILE="$2"; shift 2 ;;
        --json)     JSON_FILE="$2"; shift 2 ;;
        --only)     ONLY="$2"; shift 2 ;;
        --skip)     SKIP="$2"; shift 2 ;;
        --src)      SRC_DIR="$2"; shift 2 ;;
        --target)   TARGET_NAME="$2"; shift 2 ;;
        --config)   CONFIG_NAME="$2"; shift 2 ;;
        -h|--help)  usage ;;
        *)          echo "Bilinmeyen argüman: $1"; usage ;;
    esac
done

# ─── Repo kökü ──────────────────────────────────────────────────────────
# Caller'ın current working directory'si repo kökü kabul edilir.
# Brew install ile script libexec/'te yaşar — script konumu repo kökü DEĞİL.
REPO_ROOT="${PREFLIGHT_REPO_ROOT:-$PWD}"
cd "$REPO_ROOT"

# ─── Kaynak klasörü auto-detect ─────────────────────────────────────────
# iOS projeleri genelde kök altında <ProjectName>/ veya <ProjectName>.xcodeproj
# içerir. .xcodeproj komşusundaki klasörü tercih ederiz.
if [[ -z "$SRC_DIR" ]]; then
    XCPROJ=$(find . -maxdepth 2 -name "*.xcodeproj" -type d 2>/dev/null | head -1)
    if [[ -n "$XCPROJ" ]]; then
        BASE=$(basename "$XCPROJ" .xcodeproj)
        if [[ -d "$BASE" ]]; then
            SRC_DIR="$BASE"
        fi
    fi
    [[ -z "$SRC_DIR" ]] && SRC_DIR="."
fi

if [[ ! -d "$SRC_DIR" ]]; then
    echo "${R}Kaynak klasör bulunamadı: $SRC_DIR${NC}"
    exit 2
fi

# ─── Project introspection (target/config-aware) ────────────────────────
# --target ve --config verildiyse introspect.py çağrılır:
#   - ACTIVE_MACROS: o config için aktif Swift compilation conditions
#   - PROJECT_INFO_PLIST: o config için INFOPLIST_FILE
#   - SRC_PATHS: target'ın sync klasör listesi (multi-target için filtre)
ACTIVE_MACROS=""        # boşluk ile ayrılmış: "PROD" veya "DEBUG TEST"
PROJECT_INFO_PLIST=""
SRC_PATHS=""            # virgülle ayrılmış sync klasör listesi
INTROSPECT_PY="$(dirname "${BASH_SOURCE[0]}")/preflight-introspect.py"

if [[ -n "$CONFIG_NAME" || -n "$TARGET_NAME" ]] && [[ -f "$INTROSPECT_PY" ]]; then
    if command -v python3 >/dev/null 2>&1; then
        # JSON çıktısını ortamdan parse et
        eval "$(python3 - "$INTROSPECT_PY" "$TARGET_NAME" "$CONFIG_NAME" <<'PYEOF'
import json, subprocess, sys, shlex
introspect_py, target, config = sys.argv[1:4]
try:
    out = subprocess.run(
        [sys.executable, introspect_py],
        capture_output=True, text=True, timeout=120
    )
    if out.returncode != 0:
        print(f'echo "Introspect fail: {shlex.quote(out.stderr[-200:])}" >&2')
        sys.exit(0)
    d = json.loads(out.stdout)
    targets = d.get("targets", [])
    if not target:
        # Tek target varsa default kabul et
        if len(targets) == 1:
            target = targets[0]["name"]
    if not config:
        config = d.get("project", {}).get("defaultConfiguration", "")
    t = next((x for x in targets if x["name"] == target), None)
    if not t:
        print(f'echo "Target yok: {target}" >&2')
        sys.exit(0)
    cfg = t.get("configs", {}).get(config)
    if not cfg:
        print(f'echo "Config yok: {config}" >&2')
        sys.exit(0)
    macros = " ".join(cfg.get("macros", []))
    info_plist = cfg.get("infoPlist", "")
    src_paths = ",".join(t.get("syncFolders", []))
    print(f'TARGET_NAME={shlex.quote(target)}')
    print(f'CONFIG_NAME={shlex.quote(config)}')
    print(f'ACTIVE_MACROS={shlex.quote(macros)}')
    print(f'PROJECT_INFO_PLIST={shlex.quote(info_plist)}')
    print(f'SRC_PATHS={shlex.quote(src_paths)}')
except Exception as e:
    print(f'echo "Introspect error: {shlex.quote(str(e))}" >&2')
PYEOF
)"
    fi
fi

# Eğer SRC_PATHS varsa SRC_DIR'i ilk path'e çevir (geri uyumluluk)
if [[ -n "$SRC_PATHS" ]]; then
    SRC_DIR="${SRC_PATHS%%,*}"
fi

# ─── #if blok aktif mi? ─────────────────────────────────────────────────
# is_block_active "<condition>" — verilen #if condition'ın bu config'te
# derleneceğini söyler. ACTIVE_MACROS boşsa eski hardcode davranışa düşer.
#
# Desteklenen: "X", "!X". "X || Y" / "X && Y" → güvenlik için "active" döner
# (false-negative — hata kaçırma — yerine false-positive — fazla flag — tercih edilir).
is_block_active() {
    local cond="$1"
    cond="${cond## }"; cond="${cond%% }"

    if [[ -z "$ACTIVE_MACROS" ]]; then
        # Geri uyumluluk: eski davranış — !PROD/DEBUG/!RELEASE skip
        if [[ "$cond" =~ ^(\!PROD|DEBUG|\!RELEASE)$ ]]; then
            return 1   # block in-aktif (skip)
        fi
        return 0       # block aktif (flag)
    fi

    # Compound koşullar (||, &&) → güvenli tarafta kal: "aktif" say
    if [[ "$cond" == *"||"* || "$cond" == *"&&"* ]]; then
        return 0
    fi

    # !X formatı
    local negate=0
    if [[ "$cond" == \!* ]]; then
        negate=1
        cond="${cond#!}"
        cond="${cond## }"
    fi

    # Macro aktif mi?
    local macro_active=0
    for m in $ACTIVE_MACROS; do
        if [[ "$m" == "$cond" ]]; then macro_active=1; break; fi
    done

    if (( negate == 1 )); then
        # !X: macro aktif değilse block aktif
        (( macro_active == 0 )) && return 0 || return 1
    else
        # X: macro aktifse block aktif
        (( macro_active == 1 )) && return 0 || return 1
    fi
}

# ─── Bir kod satırı bu config'te derlenecek mi? ─────────────────────────
# should_flag_at_line <file> <line>: 0 (aktif/flag) veya 1 (inactive/skip)
# Yukarıdan aşağı en yakın #if/#elseif/#else/#endif analizi.
# Compound koşullar (||/&&) ve #elseif için "active" sayar (false-positive
# vermek false-negative'den daha güvenli).
should_flag_at_line() {
    local file="$1" line_num="$2"

    # ACTIVE_MACROS yoksa eski davranış: tüm satırlar aktif
    [[ -z "$ACTIVE_MACROS" ]] && return 0
    [[ ! -f "$file" ]] && return 0

    local start
    start=$((line_num > 300 ? line_num - 300 : 1))
    local preceding
    preceding=$(sed -n "${start},${line_num}p" "$file" 2>/dev/null)

    # En yakın preprocessor directive
    local last_directive
    last_directive=$(echo "$preceding" \
        | grep -nE '^[[:space:]]*#(if|elseif|else|endif)' | tail -1)
    [[ -z "$last_directive" ]] && return 0  # block dışı → flag

    if [[ "$last_directive" =~ \#endif ]]; then
        return 0  # block kapanmış → flag
    fi

    if [[ "$last_directive" =~ \#elseif ]]; then
        return 0  # compound, güvenli tarafa kal
    fi

    if [[ "$last_directive" =~ \#if[[:space:]]+(.+)$ ]]; then
        local cond="${BASH_REMATCH[1]%% }"
        is_block_active "$cond" && return 0 || return 1
    fi

    if [[ "$last_directive" =~ \#else ]]; then
        # #else: eşleşen #if'i depth-aware bul, tersini al
        local else_chunk_line="${last_directive%%:*}"
        local else_actual=$((start + else_chunk_line - 1))
        local depth=0
        local matching_if=""
        local i=$((else_actual - 1))
        while (( i >= 1 )); do
            local lc
            lc=$(sed -n "${i}p" "$file" 2>/dev/null)
            if [[ "$lc" =~ ^[[:space:]]*#endif ]]; then
                depth=$((depth + 1))
            elif [[ "$lc" =~ ^[[:space:]]*#if[[:space:]]+(.+)$ ]]; then
                if (( depth == 0 )); then
                    matching_if="${BASH_REMATCH[1]%% }"
                    break
                fi
                depth=$((depth - 1))
            fi
            i=$((i - 1))
        done
        [[ -z "$matching_if" ]] && return 0
        # #else, #if'in TERSİ
        if is_block_active "$matching_if"; then
            return 1   # #if aktif → #else inaktif
        else
            return 0   # #if inaktif → #else aktif
        fi
    fi

    return 0
}

# ─── İgnore listesi ─────────────────────────────────────────────────────
IGNORE_PATTERNS=()
if [[ -f .preflightignore ]]; then
    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        IGNORE_PATTERNS+=("$line")
    done < .preflightignore
fi

is_ignored() {
    local path="$1"
    for pat in "${IGNORE_PATTERNS[@]}"; do
        [[ "$path" == *"$pat"* ]] && return 0
    done
    return 1
}

# ─── Kural seçimi ───────────────────────────────────────────────────────
rule_enabled() {
    local rule="$1"
    if [[ -n "$ONLY" ]]; then
        [[ ",$ONLY," == *",$rule,"* ]]
        return $?
    fi
    if [[ -n "$SKIP" ]]; then
        [[ ",$SKIP," == *",$rule,"* ]] && return 1
    fi
    return 0
}

# ─── Sayaçlar ───────────────────────────────────────────────────────────
ERR_COUNT=0
WARN_COUNT=0
INFO_COUNT=0
declare -a REPORT_LINES=()

# JSON üretimi için: TSV temp dosyalar — script sonunda Python ile birleştirilir.
# Format: severity \t rule \t section_id \t section_title \t file \t line \t msg
TSV_FINDINGS=""
CURRENT_SECTION_ID=""
CURRENT_SECTION_TITLE=""
if [[ -n "$JSON_FILE" ]]; then
    TSV_FINDINGS=$(mktemp -t preflight-findings.XXXXXX) || TSV_FINDINGS=""
fi

emit() {
    # emit <severity> <rule> <message> [file:line]
    local sev="$1" rule="$2" msg="$3" loc="${4:-}"

    # Config-aware filtre: file:line geçilen ERR/WARN bulguları için
    # satırın bu config'te derlenip derlenmediğini kontrol et.
    # INFO ve özet mesajları (loc'suz) etkilenmez.
    if [[ "$sev" != "INFO" && -n "$loc" && "$loc" == *":"* && -n "$ACTIVE_MACROS" ]]; then
        local _file="${loc%:*}"
        local _line="${loc##*:}"
        if [[ "$_line" =~ ^[0-9]+$ ]] && [[ -f "$_file" ]]; then
            if ! should_flag_at_line "$_file" "$_line"; then
                return 0  # bu config'te derlenmez → sessizce skip
            fi
        fi
    fi

    local prefix="" color=""
    case "$sev" in
        ERR)  prefix="[ERR] "; color="$R"; ((ERR_COUNT++))  ;;
        WARN) prefix="[WARN]"; color="$Y"; ((WARN_COUNT++)) ;;
        INFO) prefix="[INFO]"; color="$B"; ((INFO_COUNT++)) ;;
    esac
    if [[ -n "$loc" ]]; then
        printf "  %s%s%s %s%s%s — %s ${DIM}(%s)${NC}\n" \
            "$color" "$prefix" "$NC" "$BOLD" "$rule" "$NC" "$msg" "$loc"
        REPORT_LINES+=("- **[$sev] $rule** — $msg \`($loc)\`")
    else
        printf "  %s%s%s %s%s%s — %s\n" \
            "$color" "$prefix" "$NC" "$BOLD" "$rule" "$NC" "$msg"
        REPORT_LINES+=("- **[$sev] $rule** — $msg")
    fi

    # JSON için TSV satırı (tab içeren metinler temizlenir)
    if [[ -n "$TSV_FINDINGS" ]]; then
        local file="" line=""
        if [[ "$loc" == *":"* ]]; then
            line="${loc##*:}"
            # line numerik mi? Değilse boş bırak.
            [[ ! "$line" =~ ^[0-9]+$ ]] && { file="$loc"; line=""; } || file="${loc%:*}"
        else
            file="$loc"
        fi
        # Tab ve newline karakterlerini temizle
        local clean_msg="${msg//$'\t'/ }"
        clean_msg="${clean_msg//$'\n'/ }"
        local clean_file="${file//$'\t'/ }"
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
            "$sev" "$rule" "$CURRENT_SECTION_ID" "$CURRENT_SECTION_TITLE" \
            "$clean_file" "$line" "$clean_msg" >> "$TSV_FINDINGS"
    fi
}

section() {
    printf "\n%s▸ %s%s\n" "$BOLD" "$1" "$NC"
    REPORT_LINES+=("" "## $1" "")
    # Section başlığını ID'ye çevir: "1. Console log..." → "1-console-log..."
    CURRENT_SECTION_TITLE="$1"
    CURRENT_SECTION_ID=$(echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]\+/-/g; s/^-\|-$//g')
}

# ─── grep wrapper (rg varsa kullan) ─────────────────────────────────────
if command -v rg >/dev/null 2>&1; then
    USE_RG=1
else
    USE_RG=0
fi

# search <regex> <glob>  → "path:line:content" satırları döndürür
search() {
    local pattern="$1" glob="${2:-*.swift}"
    if [[ $USE_RG -eq 1 ]]; then
        rg -n --no-heading --color=never -g "$glob" -- "$pattern" "$SRC_DIR" 2>/dev/null || true
    else
        # POSIX grep fallback
        find "$SRC_DIR" -type f -name "$glob" -print0 2>/dev/null \
            | xargs -0 grep -nE "$pattern" 2>/dev/null || true
    fi
}

filter_ignored() {
    while IFS= read -r line; do
        local path="${line%%:*}"
        is_ignored "$path" || echo "$line"
    done
}

# ─── Banner ─────────────────────────────────────────────────────────────
printf "%s╔════════════════════════════════════════════════════════════╗%s\n" "$BOLD" "$NC"
printf "%s║       iOS Live Preflight Check                             ║%s\n" "$BOLD" "$NC"
printf "%s╚════════════════════════════════════════════════════════════╝%s\n" "$BOLD" "$NC"
printf "  Repo  : %s\n" "$REPO_ROOT"
printf "  Kaynak: %s\n" "$SRC_DIR"
printf "  Tarih : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
[[ ${#IGNORE_PATTERNS[@]} -gt 0 ]] && printf "  Ignore: %s pattern\n" "${#IGNORE_PATTERNS[@]}"

REPORT_LINES+=("# Preflight Raporu" "")
REPORT_LINES+=("- Repo: \`$REPO_ROOT\`")
REPORT_LINES+=("- Kaynak: \`$SRC_DIR\`")
REPORT_LINES+=("- Tarih: $(date '+%Y-%m-%d %H:%M:%S')")

# ═══════════════════════════════════════════════════════════════════════
# KURAL 1: print / NSLog / debugPrint / dump (loglama sızıntısı)
# ═══════════════════════════════════════════════════════════════════════
if rule_enabled print; then
    section "Console log sızıntıları (print/NSLog/debugPrint/dump)"

    # Wrap edilmemiş çıplak print: satır başında veya boşluktan sonra `print(`
    # word-boundary ile `debugPrint`/`fingerprint`/`reprint` yakalanmaz.
    local_results=$(search '(^|[^A-Za-z0-9_])(print|NSLog|debugPrint|dump)\(' | filter_ignored)

    if [[ -n "$local_results" ]]; then
        # `#if !PROD` / `#if DEBUG` bloğu içinde olanları ayırmak için
        # her dosyada print satırı üzerinde yukarı 30 satır içinde
        # `#if !PROD|#if DEBUG|#if !RELEASE` arıyoruz, yoksa unguarded sayılıyor.
        unguarded_count=0
        while IFS= read -r match; do
            [[ -z "$match" ]] && continue
            file="${match%%:*}"
            rest="${match#*:}"
            line_num="${rest%%:*}"

            # Yorum satırı mı? skip
            content_line=$(sed -n "${line_num}p" "$file" 2>/dev/null)
            [[ "$content_line" =~ ^[[:space:]]*// ]] && continue

            # Yukarıda en yakın `#if` veya `#endif` ara
            start=$((line_num - 50))
            (( start < 1 )) && start=1
            preceding=$(sed -n "${start},${line_num}p" "$file" 2>/dev/null)
            last_if=$(echo "$preceding" | grep -nE '^[[:space:]]*#(if|endif)' | tail -1)

            # En yakın #endif ise block dışındayız → flag at
            # Aksi halde #if X içindeyiz → X bu config'te aktif mi?
            if [[ "$last_if" =~ \#if[[:space:]]+(.+)$ ]]; then
                cond="${BASH_REMATCH[1]}"
                # Trailing whitespace'i temizle
                cond="${cond%% }"
                if ! is_block_active "$cond"; then
                    continue   # bu config'te derlenmez → skip
                fi
            fi

            snippet=$(echo "$content_line" | sed 's/^[[:space:]]*//' | cut -c1-80)
            emit ERR print "$snippet" "$file:$line_num"
            unguarded_count=$((unguarded_count + 1))
        done <<< "$local_results"

        if [[ $unguarded_count -eq 0 ]]; then
            emit INFO print "Tüm log çağrıları #if !PROD/DEBUG bloğunda — temiz."
        fi
    else
        emit INFO print "Console log çağrısı bulunamadı."
    fi
fi

# ═══════════════════════════════════════════════════════════════════════
# KURAL 2: Force unwrap & try! & fatalError
# ═══════════════════════════════════════════════════════════════════════
if rule_enabled unsafe; then
    section "Güvenli olmayan ifadeler (try! / fatalError / as!)"

    # try!
    while IFS= read -r m; do
        [[ -z "$m" ]] && continue
        file="${m%%:*}"; rest="${m#*:}"; line_num="${rest%%:*}"
        emit WARN try-bang "try! kullanımı" "$file:$line_num"
    done < <(search 'try!' | filter_ignored)

    # fatalError (release'de crash sebebi)
    while IFS= read -r m; do
        [[ -z "$m" ]] && continue
        file="${m%%:*}"; rest="${m#*:}"; line_num="${rest%%:*}"
        content_line=$(sed -n "${line_num}p" "$file" 2>/dev/null)
        [[ "$content_line" =~ ^[[:space:]]*// ]] && continue
        emit WARN fatal-error "fatalError() — release'de crash riski" "$file:$line_num"
    done < <(search 'fatalError\(' | filter_ignored)

    # as! force cast
    while IFS= read -r m; do
        [[ -z "$m" ]] && continue
        file="${m%%:*}"; rest="${m#*:}"; line_num="${rest%%:*}"
        content_line=$(sed -n "${line_num}p" "$file" 2>/dev/null)
        [[ "$content_line" =~ ^[[:space:]]*// ]] && continue
        emit WARN force-cast "as! force cast" "$file:$line_num"
    done < <(search ' as! ' | filter_ignored)
fi

# ═══════════════════════════════════════════════════════════════════════
# KURAL 3: TODO / FIXME / HACK / XXX
# ═══════════════════════════════════════════════════════════════════════
if rule_enabled todo; then
    section "Tamamlanmamış işaretler (TODO/FIXME/HACK)"
    todo_found=0
    while IFS= read -r m; do
        [[ -z "$m" ]] && continue
        file="${m%%:*}"; rest="${m#*:}"; line_num="${rest%%:*}"
        body="${m#*:*:}"
        # uzun mesajları kısalt
        body=$(echo "$body" | sed 's/^[[:space:]]*//' | cut -c1-80)
        emit WARN todo "$body" "$file:$line_num"
        ((todo_found++))
    done < <(search '//[[:space:]]*(TODO|FIXME|HACK|XXX)' | filter_ignored)

    [[ $todo_found -eq 0 ]] && emit INFO todo "Tamamlanmamış işaret yok."
fi

# ═══════════════════════════════════════════════════════════════════════
# KURAL 4: Hardcoded HTTP / IP / localhost
# ═══════════════════════════════════════════════════════════════════════
if rule_enabled http; then
    section "Hardcoded HTTP / IP / localhost"

    while IFS= read -r m; do
        [[ -z "$m" ]] && continue
        file="${m%%:*}"; rest="${m#*:}"; line_num="${rest%%:*}"
        content_line=$(sed -n "${line_num}p" "$file" 2>/dev/null)
        [[ "$content_line" =~ ^[[:space:]]*// ]] && continue
        # https:// alt-string'i içeriyorsa skip
        [[ "$content_line" =~ https:// ]] && continue
        emit ERR http-url "Düz HTTP URL (TLS yok)" "$file:$line_num"
    done < <(search 'http://[^"]+' | filter_ignored)

    while IFS= read -r m; do
        [[ -z "$m" ]] && continue
        file="${m%%:*}"; rest="${m#*:}"; line_num="${rest%%:*}"
        content_line=$(sed -n "${line_num}p" "$file" 2>/dev/null)
        [[ "$content_line" =~ ^[[:space:]]*// ]] && continue
        emit ERR localhost "localhost / private IP referansı" "$file:$line_num"
    done < <(search '(localhost|127\.0\.0\.1|192\.168\.|10\.0\.0\.)' | filter_ignored)
fi

# ═══════════════════════════════════════════════════════════════════════
# KURAL 5: Hardcoded secrets (basic regex)
# ═══════════════════════════════════════════════════════════════════════
if rule_enabled secrets; then
    section "Hardcoded secret şüphesi"

    # 32+ karakter base64 / hex literal'leri (key/token paterni)
    # API key / token / password / secret = "..." atamaları
    while IFS= read -r m; do
        [[ -z "$m" ]] && continue
        file="${m%%:*}"; rest="${m#*:}"; line_num="${rest%%:*}"
        body=$(echo "${m#*:*:}" | cut -c1-100)
        emit WARN secret "Şüpheli atama: $(echo "$body" | sed 's/^[[:space:]]*//')" "$file:$line_num"
    done < <(search '(apiKey|api_key|secret|password|token|authToken)[[:space:]]*=[[:space:]]*"[A-Za-z0-9_/+=-]{16,}"' | filter_ignored)
fi

# ═══════════════════════════════════════════════════════════════════════
# KURAL 6: Test/Mock dosyaları Prod target'da kalmış mı?
# ═══════════════════════════════════════════════════════════════════════
if rule_enabled mock; then
    section "Mock / Stub / Fake dosyalar (Prod target'a sızabilir)"

    PBXPROJ=$(find . -maxdepth 3 -name "project.pbxproj" 2>/dev/null | head -1)

    # Xcode 16 "synchronized folder" varsa tüm dosyalar Prod'a otomatik dahil
    SYNC_GROUP=0
    if [[ -n "$PBXPROJ" ]] && grep -q "fileSystemSynchronizedGroups" "$PBXPROJ" 2>/dev/null; then
        SYNC_GROUP=1
    fi

    mock_files=$(find "$SRC_DIR" -type f \( -iname "*Mock*.swift" -o -iname "*Stub*.swift" -o -iname "*Fake*.swift" \) 2>/dev/null)
    mock_count=0
    if [[ -n "$mock_files" ]]; then
        while IFS= read -r mf; do
            [[ -z "$mf" ]] && continue
            is_ignored "$mf" && continue
            fname=$(basename "$mf")
            in_target=0
            if (( SYNC_GROUP == 1 )); then
                in_target=1  # synchronized → otomatik dahil
            elif [[ -n "$PBXPROJ" ]] && grep -q "$fname" "$PBXPROJ" 2>/dev/null; then
                in_target=1
            fi
            if (( in_target == 1 )); then
                # Dosyanın ilk non-blank, non-comment satırı bir #if ise condition kontrol et
                first_nonblank=$(grep -nE "[^[:space:]]" "$mf" 2>/dev/null | grep -vE "^[0-9]+:[[:space:]]*//" | head -1)
                if [[ "$first_nonblank" =~ \#if[[:space:]]+(.+)$ ]]; then
                    file_cond="${BASH_REMATCH[1]%% }"
                    if ! is_block_active "$file_cond"; then
                        continue  # bu config'te derlenmez
                    fi
                fi
                emit WARN mock-in-target "Mock/Stub Prod target'ında: $fname" "$mf"
                mock_count=$((mock_count + 1))
            fi
        done <<< "$mock_files"
    fi

    if [[ -z "$mock_files" ]]; then
        emit INFO mock "Mock dosya bulunamadı."
    elif (( mock_count == 0 )); then
        emit INFO mock "Tüm mock dosyaları #if !PROD ile gateli."
    fi
fi

# ═══════════════════════════════════════════════════════════════════════
# KURAL 7: ATS (App Transport Security)
# ═══════════════════════════════════════════════════════════════════════
if rule_enabled ats; then
    section "App Transport Security (Info.plist)"

    PLIST=$(find "$SRC_DIR" -maxdepth 2 -name "Info.plist" -type f 2>/dev/null | head -1)
    if [[ -n "$PLIST" ]]; then
        if grep -A1 "NSAllowsArbitraryLoads" "$PLIST" 2>/dev/null | grep -q "<true/>"; then
            emit ERR ats-disabled "NSAllowsArbitraryLoads = true (ATS tamamen kapalı)" "$PLIST"
        fi
        if grep -A1 "NSAllowsArbitraryLoadsInWebContent" "$PLIST" 2>/dev/null | grep -q "<true/>"; then
            emit WARN ats-web "NSAllowsArbitraryLoadsInWebContent = true" "$PLIST"
        fi
        if grep -A1 "NSExceptionAllowsInsecureHTTPLoads" "$PLIST" 2>/dev/null | grep -q "<true/>"; then
            emit WARN ats-exception "NSExceptionAllowsInsecureHTTPLoads = true (domain exception)" "$PLIST"
        fi
    else
        emit INFO ats "Info.plist bulunamadı."
    fi
fi

# ═══════════════════════════════════════════════════════════════════════
# KURAL 8: Build Configuration sızıntısı (Test/UAT URL'i kodda)
# ═══════════════════════════════════════════════════════════════════════
if rule_enabled env; then
    section "Environment sızıntısı (Test/UAT/Dev hardcoded)"

    while IFS= read -r m; do
        [[ -z "$m" ]] && continue
        file="${m%%:*}"; rest="${m#*:}"; line_num="${rest%%:*}"
        content_line=$(sed -n "${line_num}p" "$file" 2>/dev/null)
        [[ "$content_line" =~ ^[[:space:]]*// ]] && continue
        # xcconfig dosyalarını atla
        [[ "$file" =~ \.xcconfig$ ]] && continue
        emit WARN env-leak "Test/UAT/Dev string'i kodda" "$file:$line_num"
    done < <(search '"[^"]*(\.test\.|\.uat\.|-tst-|-uat-|-dev-|staging\.)[^"]*"' | filter_ignored)
fi

# ═══════════════════════════════════════════════════════════════════════
# KURAL 9: Yorum satırına alınmış kod blokları
# ═══════════════════════════════════════════════════════════════════════
if rule_enabled commented; then
    section "Yorum satırına alınmış kod blokları"

    # bash 3.2 uyumlu: dosya başına sayım için `awk`
    found=0
    counts=$(search '^[[:space:]]*//[[:space:]]*(let|var|func|if|guard|return|self\.|@)' \
        | filter_ignored \
        | awk -F: '{ counts[$1]++ } END { for (f in counts) if (counts[f] >= 3) printf "%d\t%s\n", counts[f], f }')

    if [[ -n "$counts" ]]; then
        while IFS=$'\t' read -r cnt file; do
            [[ -z "$file" ]] && continue
            emit WARN commented-code "$cnt yorum satırına alınmış kod satırı" "$file"
            found=$((found + 1))
        done <<< "$counts"
    fi
    [[ $found -eq 0 ]] && emit INFO commented-code "Toplu yorumlanmış kod bloğu yok."
fi

# ═══════════════════════════════════════════════════════════════════════
# KURAL 10: SwiftLint disable
# ═══════════════════════════════════════════════════════════════════════
if rule_enabled lint; then
    section "SwiftLint disable bildirimleri"

    while IFS= read -r m; do
        [[ -z "$m" ]] && continue
        file="${m%%:*}"; rest="${m#*:}"; line_num="${rest%%:*}"
        body=$(echo "${m#*:*:}" | sed 's/^[[:space:]]*//' | cut -c1-80)
        emit INFO swiftlint "$body" "$file:$line_num"
    done < <(search '//[[:space:]]*swiftlint:disable' | filter_ignored)
fi

# ═══════════════════════════════════════════════════════════════════════
# KURAL 11: Info.plist gerekli izin açıklamaları
# ═══════════════════════════════════════════════════════════════════════
if rule_enabled plist; then
    section "Info.plist usage description'ları"

    PLIST=$(find "$SRC_DIR" -maxdepth 2 -name "Info.plist" -type f 2>/dev/null | head -1)
    if [[ -n "$PLIST" ]]; then
        # bash 3.2 uyumlu: paralel diziler (kod kalıbı | plist anahtarı)
        perm_pairs=(
            "AVCaptureDeviceAccess|UIImagePickerController|AVCaptureSession::NSCameraUsageDescription"
            "PHPhotoLibrary|UIImagePickerControllerSourceTypePhotoLibrary::NSPhotoLibraryUsageDescription"
            "CLLocationManager::NSLocationWhenInUseUsageDescription"
            "LAContext|LocalAuthentication::NSFaceIDUsageDescription"
            "CNContactStore::NSContactsUsageDescription"
            "AVAudioRecorder|AVAudioSession\\.sharedInstance::NSMicrophoneUsageDescription"
            "ATTrackingManager::NSUserTrackingUsageDescription"
            "CBCentralManager|CBPeripheralManager::NSBluetoothAlwaysUsageDescription"
            "CMMotionManager|CMPedometer::NSMotionUsageDescription"
            "EKEventStore::NSCalendarsUsageDescription"
            "SFSpeechRecognizer::NSSpeechRecognitionUsageDescription"
            "MPMediaLibrary::NSAppleMusicUsageDescription"
        )
        plist_problems=0
        for pair in "${perm_pairs[@]}"; do
            code_pattern="${pair%%::*}"
            plist_key="${pair##*::}"
            if search "($code_pattern)" | filter_ignored | head -1 | grep -q .; then
                if ! grep -q "<key>$plist_key</key>" "$PLIST" 2>/dev/null; then
                    emit ERR plist-permission "$plist_key eksik (kod $code_pattern kullanıyor)" "$PLIST"
                    plist_problems=$((plist_problems + 1))
                else
                    desc=$(grep -A1 "<key>$plist_key</key>" "$PLIST" | tail -1 | sed 's/<[^>]*>//g' | xargs)
                    if [[ -z "$desc" ]]; then
                        emit ERR plist-permission "$plist_key açıklaması boş" "$PLIST"
                        plist_problems=$((plist_problems + 1))
                    fi
                fi
            fi
        done
        [[ $plist_problems -eq 0 ]] && emit INFO plist "Usage description kontrolü tamam."
    fi
fi

# ═══════════════════════════════════════════════════════════════════════
# KURAL 12: xcconfig — Prod ayarları
# ═══════════════════════════════════════════════════════════════════════
if rule_enabled config; then
    section "Build Configuration (Prod.xcconfig)"

    PROD_XC=$(find . -maxdepth 5 -iname "Prod.xcconfig" -type f 2>/dev/null | head -1)
    if [[ -n "$PROD_XC" ]]; then
        if ! grep -qi "MARKETING_VERSION\|baseUrl" "$PROD_XC"; then
            emit WARN xcconfig-prod "Prod.xcconfig içinde MARKETING_VERSION/baseUrl yok" "$PROD_XC"
        fi
        # Prod URL gerçekten prod-like mı?
        if grep -qiE "(test|uat|dev|staging|tst-)" "$PROD_XC"; then
            emit ERR xcconfig-prod-leak "Prod.xcconfig içinde test/uat/dev string'i var" "$PROD_XC"
        fi
    else
        emit INFO xcconfig-prod "Prod.xcconfig bulunamadı, atlanıyor."
    fi
fi

# ═══════════════════════════════════════════════════════════════════════
# KURAL 13: Asset eksiği (UIImage(named:) referansları)
# ═══════════════════════════════════════════════════════════════════════
if rule_enabled assets; then
    section "Eksik asset referansları"

    XCASSETS=$(find "$SRC_DIR" -maxdepth 3 -name "*.xcassets" -type d 2>/dev/null | head -1)
    if [[ -n "$XCASSETS" ]]; then
        # asset isimlerini topla (folder adlarından .imageset'i strip)
        existing_assets=$(find "$XCASSETS" -name "*.imageset" -type d 2>/dev/null | xargs -n1 basename 2>/dev/null | sed 's/\.imageset$//')

        # kodda Image("...") veya UIImage(named: "...") çağrılarını topla
        missing=0
        while IFS= read -r m; do
            [[ -z "$m" ]] && continue
            file="${m%%:*}"; rest="${m#*:}"; line_num="${rest%%:*}"
            # asset adını çek
            content_line=$(sed -n "${line_num}p" "$file" 2>/dev/null)
            asset=$(echo "$content_line" | grep -oE '"[^"]+"' | head -1 | tr -d '"')
            [[ -z "$asset" ]] && continue
            # SF Symbol veya system image olabilir
            [[ "$asset" =~ ^systemName ]] && continue
            if ! echo "$existing_assets" | grep -qx "$asset"; then
                # SF Symbol mü kontrol et: küçük harf + nokta veya tire
                [[ "$asset" =~ ^[a-z][a-z0-9.-]*$ ]] && continue
                emit WARN missing-asset "Asset bulunamadı: $asset" "$file:$line_num"
                ((missing++))
                # Çok uzamasın
                (( missing > 30 )) && { emit INFO missing-asset "...30+ eksik asset, kalan listelenmedi."; break; }
            fi
        done < <(search '(UIImage\(named:[[:space:]]*|Image\()"[A-Z][A-Za-z0-9_]+"' | filter_ignored)

        [[ $missing -eq 0 ]] && emit INFO assets "Asset referansları tamam."
    fi
fi

# ═══════════════════════════════════════════════════════════════════════
# KURAL 14: PrivacyInfo.xcprivacy varlığı + Required Reason API
# Submission blocker: May 2024'ten beri zorunlu.
# ═══════════════════════════════════════════════════════════════════════
if rule_enabled privacy-manifest; then
    section "Privacy Manifest (PrivacyInfo.xcprivacy)"

    # Build output'taki 3rd-party manifest'leri saymak istemiyoruz, sadece kaynak.
    PRIVACY_FILE=$(find "$SRC_DIR" -maxdepth 4 -name "PrivacyInfo.xcprivacy" -type f 2>/dev/null \
                   | grep -v "/build/" | grep -v "\.xcarchive/" | head -1)

    if [[ -z "$PRIVACY_FILE" ]]; then
        emit ERR privacy-manifest "PrivacyInfo.xcprivacy bulunamadı (May 2024'ten beri zorunlu)"
    else
        # Required Reason API'lar kullanılıyor mu, manifest'te tag var mı?
        # Tag → API map (paralel diziler)
        api_pairs=(
            "UserDefaults::NSPrivacyAccessedAPICategoryUserDefaults"
            "modificationDate|attributesOfItem|attributesOfFileSystem::NSPrivacyAccessedAPICategoryFileTimestamp"
            "systemUptime|mach_absolute_time::NSPrivacyAccessedAPICategorySystemBootTime"
            "volumeAvailableCapacity|volumeTotalCapacity::NSPrivacyAccessedAPICategoryDiskSpace"
            "UITextInputMode\\.activeInputModes::NSPrivacyAccessedAPICategoryActiveKeyboards"
        )
        manifest_problems=0
        for pair in "${api_pairs[@]}"; do
            code_pat="${pair%%::*}"
            tag="${pair##*::}"
            if search "($code_pat)" | filter_ignored | head -1 | grep -q .; then
                if ! grep -q "$tag" "$PRIVACY_FILE" 2>/dev/null; then
                    emit ERR privacy-reason "$tag eksik (kod $code_pat kullanıyor)" "$PRIVACY_FILE"
                    manifest_problems=$((manifest_problems + 1))
                fi
            fi
        done
        [[ $manifest_problems -eq 0 ]] && emit INFO privacy-manifest "Privacy manifest tamam."
    fi
fi

# ═══════════════════════════════════════════════════════════════════════
# KURAL 15: SDK / Deployment target — App Store policy
# Nisan 2026'dan itibaren tüm submission'lar Xcode 26 + iOS 18 SDK gerektirir.
# ═══════════════════════════════════════════════════════════════════════
if rule_enabled sdk; then
    section "SDK & Deployment Target"

    PBXPROJ=$(find . -maxdepth 3 -name "project.pbxproj" 2>/dev/null | head -1)
    if [[ -n "$PBXPROJ" ]]; then
        deployment=$(grep -E "IPHONEOS_DEPLOYMENT_TARGET" "$PBXPROJ" | head -1 \
                     | sed -E 's/.*= ([0-9.]+);.*/\1/')
        if [[ -n "$deployment" ]]; then
            major="${deployment%%.*}"
            if [[ "$major" =~ ^[0-9]+$ ]] && (( major < 16 )); then
                emit WARN sdk-target "iOS deployment target $deployment çok eski (modern API'lar yok)"
            else
                emit INFO sdk-target "Deployment target: iOS $deployment"
            fi
        fi
    fi

    # Xcode versiyonu — local install kontrolü
    if command -v xcodebuild >/dev/null 2>&1; then
        xc_version=$(xcodebuild -version 2>/dev/null | head -1 | awk '{print $2}')
        if [[ -n "$xc_version" ]]; then
            xc_major="${xc_version%%.*}"
            if [[ "$xc_major" =~ ^[0-9]+$ ]] && (( xc_major < 16 )); then
                emit ERR sdk-xcode "Xcode $xc_version eski — Nisan 2026'dan beri Xcode 16+ zorunlu"
            else
                emit INFO sdk-xcode "Xcode $xc_version"
            fi
        fi
    fi
fi

# ═══════════════════════════════════════════════════════════════════════
# KURAL 16: Closure'da [weak self] eksikliği
# Retain cycle'a yol açan en yaygın pattern.
# ═══════════════════════════════════════════════════════════════════════
if rule_enabled weak-self; then
    section "Closure'da [weak self] eksikliği (retain cycle riski)"

    # ".sink {", ".receive { ", "Task {" gibi closure başlangıçları sonrası
    # multiline self. kullanımı varsa flag'le.
    # Heuristik: aynı satırda "{ [weak self]" yoksa ve sonraki ~30 satırda "self." varsa.
    weak_problems=0
    while IFS= read -r m; do
        [[ -z "$m" ]] && continue
        file="${m%%:*}"; rest="${m#*:}"; line_num="${rest%%:*}"
        # Aynı veya sonraki satırda [weak self] var mı?
        end=$((line_num + 30))
        chunk=$(sed -n "${line_num},${end}p" "$file" 2>/dev/null)
        # Eğer chunk içinde [weak self] veya [unowned self] varsa skip
        if echo "$chunk" | grep -qE '\[(weak|unowned)\s+self\]'; then
            continue
        fi
        # Chunk'ta self. kullanımı var mı?
        if ! echo "$chunk" | grep -qE '\bself\.'; then
            continue
        fi
        emit WARN weak-self "Closure'da [weak self] yok ama self. kullanılıyor" "$file:$line_num"
        weak_problems=$((weak_problems + 1))
        # Çok uzamasın
        (( weak_problems > 40 )) && { emit INFO weak-self "...40+ bulgu, kalan listelenmedi."; break; }
    done < <(search '\.(sink|receive|store|map|flatMap)\s*\{[[:space:]]*$|^\s*Task\s*\{[[:space:]]*$|^\s*Task\.detached\s*\{' | filter_ignored)

    [[ $weak_problems -eq 0 ]] && emit INFO weak-self "Closure'larda weak self düzeni temiz."
fi

# ═══════════════════════════════════════════════════════════════════════
# KURAL 17: var delegate / dataSource — weak olmalı
# ═══════════════════════════════════════════════════════════════════════
if rule_enabled weak-delegate; then
    section "Delegate / DataSource weak değil"

    found=0
    while IFS= read -r m; do
        [[ -z "$m" ]] && continue
        file="${m%%:*}"; rest="${m#*:}"; line_num="${rest%%:*}"
        content=$(sed -n "${line_num}p" "$file" 2>/dev/null)
        # Yorum satırı atla
        [[ "$content" =~ ^[[:space:]]*// ]] && continue
        # Zaten weak ise atla
        [[ "$content" =~ weak[[:space:]]+var ]] && continue
        emit WARN weak-delegate "delegate/dataSource weak değil" "$file:$line_num"
        found=$((found + 1))
    done < <(search '^\s*(public|private|internal|fileprivate)?\s*var\s+(delegate|dataSource)\s*:' | filter_ignored)

    [[ $found -eq 0 ]] && emit INFO weak-delegate "Tüm delegate/dataSource weak."
fi

# ═══════════════════════════════════════════════════════════════════════
# KURAL 18: Pasteboard güvenliği — banking için hassas veri kopyalama
# ═══════════════════════════════════════════════════════════════════════
if rule_enabled pasteboard; then
    section "Pasteboard güvenliği (hassas veri kopyalama)"

    found=0
    while IFS= read -r m; do
        [[ -z "$m" ]] && continue
        file="${m%%:*}"; rest="${m#*:}"; line_num="${rest%%:*}"
        content=$(sed -n "${line_num}p" "$file" 2>/dev/null)
        [[ "$content" =~ ^[[:space:]]*// ]] && continue
        snippet=$(echo "$content" | sed 's/^[[:space:]]*//' | cut -c1-90)
        # Hassas anahtar kelime varsa ERR, yoksa WARN
        if echo "$content" | grep -qiE "(card|pin|cvv|password|iban|customerNumber|account)"; then
            emit ERR pasteboard "Hassas veri pasteboard'a yazılıyor: $snippet" "$file:$line_num"
        else
            emit WARN pasteboard "Pasteboard yazma: $snippet" "$file:$line_num"
        fi
        found=$((found + 1))
    done < <(search 'UIPasteboard\.general\.(string\s*=|setValue\(|setItems\()' | filter_ignored)

    [[ $found -eq 0 ]] && emit INFO pasteboard "Pasteboard yazma yok."
fi

# ═══════════════════════════════════════════════════════════════════════
# KURAL 19: Hassas log — log fonksiyonuna password/pin/cvv geçilmesi
# ═══════════════════════════════════════════════════════════════════════
if rule_enabled sensitive-log; then
    section "Hassas log argümanları"

    found=0
    while IFS= read -r m; do
        [[ -z "$m" ]] && continue
        file="${m%%:*}"; rest="${m#*:}"; line_num="${rest%%:*}"
        content=$(sed -n "${line_num}p" "$file" 2>/dev/null)
        [[ "$content" =~ ^[[:space:]]*// ]] && continue
        snippet=$(echo "$content" | sed 's/^[[:space:]]*//' | cut -c1-90)
        emit ERR sensitive-log "Log'da hassas alan referansı: $snippet" "$file:$line_num"
        found=$((found + 1))
    done < <(search '(print|NSLog|debugPrint|dump|log|os_log|Logger\(\)\.\w+)\(.*\b(password|pin|cvv|cardNumber|cardNo|fullCardNumber|otp|token|authToken|accessToken|refreshToken|customerNumber|tckn|tcKimlik)\b' | filter_ignored)

    [[ $found -eq 0 ]] && emit INFO sensitive-log "Hassas log argümanı yok."
fi

# ═══════════════════════════════════════════════════════════════════════
# KURAL 20: Deprecated iOS API'lar
# ═══════════════════════════════════════════════════════════════════════
if rule_enabled deprecated; then
    section "Deprecated iOS API kullanımları"

    declare -a dep_pairs=(
        "UIScreen\\.main::UIScreen.main (iOS 16+ deprecated, UIWindowScene.screen kullan)"
        "UIApplication\\.shared\\.windows::UIApplication.shared.windows (iOS 15+ deprecated, connectedScenes kullan)"
        "UIApplication\\.shared\\.keyWindow::UIApplication.shared.keyWindow (iOS 13+ deprecated)"
        "UIApplication\\.shared\\.statusBarOrientation::statusBarOrientation (iOS 13+ deprecated)"
        "NavigationLink\\(destination:::NavigationLink(destination:) (iOS 16+ deprecated, NavigationStack + .navigationDestination kullan)"
    )

    found=0
    for pair in "${dep_pairs[@]}"; do
        code="${pair%%::*}"
        msg="${pair##*::}"
        while IFS= read -r m; do
            [[ -z "$m" ]] && continue
            file="${m%%:*}"; rest="${m#*:}"; line_num="${rest%%:*}"
            content=$(sed -n "${line_num}p" "$file" 2>/dev/null)
            [[ "$content" =~ ^[[:space:]]*// ]] && continue
            emit WARN deprecated "$msg" "$file:$line_num"
            found=$((found + 1))
        done < <(search "$code" | filter_ignored)
    done

    [[ $found -eq 0 ]] && emit INFO deprecated "Deprecated API kullanımı yok."
fi

# ═══════════════════════════════════════════════════════════════════════
# KURAL 21: Localization dışı hardcoded string'ler
# Proje L10.X.y enum kullanıyor — Text("..."), Button("...") direkt literal'ler
# muhtemelen unutulmuş.
# ═══════════════════════════════════════════════════════════════════════
if rule_enabled hardcoded-string; then
    section "Localization dışı hardcoded UI string'leri"

    found=0
    # Text("Merhaba") veya Button("Save") gibi — sadece harf/boşluk içeren,
    # 3+ karakterli, identifier/asset adı olmayan string'ler.
    while IFS= read -r m; do
        [[ -z "$m" ]] && continue
        file="${m%%:*}"; rest="${m#*:}"; line_num="${rest%%:*}"
        content=$(sed -n "${line_num}p" "$file" 2>/dev/null)
        [[ "$content" =~ ^[[:space:]]*// ]] && continue
        # asset/identifier şüphesi: sadece kebab-case veya snake_case ise atla
        literal=$(echo "$content" | grep -oE '"[^"]+"' | head -1)
        [[ -z "$literal" ]] && continue
        inner=$(echo "$literal" | tr -d '"')
        # Kısa veya identifier-like: atla
        [[ ${#inner} -lt 3 ]] && continue
        [[ "$inner" =~ ^[a-z][a-zA-Z0-9_-]*$ ]] && continue  # camelCase id
        [[ "$inner" =~ ^[a-z]+([A-Z][a-z]+)*$ ]] && continue  # camelCase
        # En az bir boşluk veya 2+ kelime ve harfler insan dilinde olmalı
        if [[ "$inner" =~ [[:space:]] ]] || [[ ${#inner} -gt 12 ]]; then
            snippet=$(echo "$content" | sed 's/^[[:space:]]*//' | cut -c1-90)
            emit WARN hardcoded-string "L10 dışı string: $snippet" "$file:$line_num"
            found=$((found + 1))
            (( found > 30 )) && { emit INFO hardcoded-string "...30+ bulgu, kalan listelenmedi."; break; }
        fi
    done < <(search '(Text|Button|Label|Toggle|TextField|SecureField|Picker)\(\s*"[A-ZÇĞİÖŞÜa-zçğıöşü][^"]{2,}"' | filter_ignored)

    [[ $found -eq 0 ]] && emit INFO hardcoded-string "L10 dışı string yok."
fi

# ═══════════════════════════════════════════════════════════════════════
# KURAL 22: Git durumu — uncommitted / unpushed
# ═══════════════════════════════════════════════════════════════════════
if rule_enabled git; then
    section "Git durumu"

    if git rev-parse --git-dir >/dev/null 2>&1; then
        if ! git diff-index --quiet HEAD -- 2>/dev/null; then
            emit WARN git-dirty "Commit edilmemiş değişiklikler var (uncommitted)"
        fi
        # Untracked dosyalar
        untracked=$(git ls-files --others --exclude-standard 2>/dev/null | wc -l | xargs)
        if [[ "$untracked" -gt 0 ]]; then
            emit INFO git-untracked "$untracked untracked dosya"
        fi
        # Branch ahead/behind
        upstream=$(git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null || echo "")
        if [[ -n "$upstream" ]]; then
            ahead=$(git rev-list --count @{u}..HEAD 2>/dev/null || echo 0)
            behind=$(git rev-list --count HEAD..@{u} 2>/dev/null || echo 0)
            (( ahead > 0 )) && emit INFO git-ahead "$ahead unpushed commit"
            (( behind > 0 )) && emit WARN git-behind "$behind commit upstream'in gerisinde"
        fi
    fi
fi

# ═══════════════════════════════════════════════════════════════════════
# Özet
# ═══════════════════════════════════════════════════════════════════════
printf "\n%s═══ ÖZET ═══%s\n" "$BOLD" "$NC"
printf "  %sERROR : %d%s\n" "$R"  "$ERR_COUNT"  "$NC"
printf "  %sWARN  : %d%s\n" "$Y"  "$WARN_COUNT" "$NC"
printf "  %sINFO  : %d%s\n" "$B"  "$INFO_COUNT" "$NC"

if (( ERR_COUNT > 0 )); then
    printf "\n%s✗ LIVE'A ÇIKILMAMALI — %d kritik bulgu var.%s\n" "$R" "$ERR_COUNT" "$NC"
elif (( WARN_COUNT > 0 )); then
    if (( STRICT == 1 )); then
        printf "\n%s✗ STRICT MODE — %d uyarı fail kabul edildi.%s\n" "$R" "$WARN_COUNT" "$NC"
    else
        printf "\n%s⚠ UYARILARLA TEMIZ — %d uyarıyı gözden geçir.%s\n" "$Y" "$WARN_COUNT" "$NC"
    fi
else
    printf "\n%s✓ TEMIZ — live'a çıkılabilir.%s\n" "$G" "$NC"
fi

# Markdown raporu
if [[ -n "$REPORT_FILE" ]]; then
    {
        printf "%s\n" "${REPORT_LINES[@]}"
        printf "\n## Özet\n\n"
        printf "| Severity | Count |\n|---|---|\n"
        printf "| ERROR | %d |\n| WARN | %d |\n| INFO | %d |\n" \
            "$ERR_COUNT" "$WARN_COUNT" "$INFO_COUNT"
    } > "$REPORT_FILE"
    printf "\nMarkdown rapor: %s\n" "$REPORT_FILE"
fi

# JSON raporu (dashboard için)
if [[ -n "$JSON_FILE" && -n "$TSV_FINDINGS" ]]; then
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$TSV_FINDINGS" "$JSON_FILE" \
            "$REPO_ROOT" "$SRC_DIR" "$ERR_COUNT" "$WARN_COUNT" "$INFO_COUNT" \
            "$STRICT" "$TARGET_NAME" "$CONFIG_NAME" "$ACTIVE_MACROS" <<'PYEOF'
import json, sys, datetime, os

tsv_path, json_path, repo, src, err, warn, info, strict, target, config, macros = sys.argv[1:12]

rules = {}        # section_id -> {title, findings: [...]}
rule_order = []   # section appearance order

with open(tsv_path, encoding="utf-8", errors="replace") as f:
    for raw in f:
        line = raw.rstrip("\n")
        if not line:
            continue
        parts = line.split("\t")
        # sev, rule, section_id, section_title, file, line, msg
        while len(parts) < 7:
            parts.append("")
        sev, rule_id, sec_id, sec_title, fpath, fline, msg = parts[:7]
        if not sec_id:
            sec_id = "uncategorized"
            sec_title = "Diğer"
        if sec_id not in rules:
            rules[sec_id] = {"id": sec_id, "title": sec_title, "findings": []}
            rule_order.append(sec_id)
        rules[sec_id]["findings"].append({
            "severity": sev,
            "rule": rule_id,
            "file": fpath or None,
            "line": int(fline) if fline.isdigit() else None,
            "message": msg,
        })

doc = {
    "meta": {
        "repo": repo,
        "src": src,
        "generatedAt": datetime.datetime.now().isoformat(timespec="seconds"),
        "strict": strict == "1",
        "target": target or None,
        "config": config or None,
        "activeMacros": macros.split() if macros else [],
        "totals": {
            "error": int(err),
            "warn": int(warn),
            "info": int(info),
        },
        "verdict": (
            "fail" if int(err) > 0
            else ("fail" if (strict == "1" and int(warn) > 0)
                  else ("warn" if int(warn) > 0 else "pass"))
        ),
    },
    "sections": [rules[sid] for sid in rule_order],
}

with open(json_path, "w", encoding="utf-8") as out:
    json.dump(doc, out, ensure_ascii=False, indent=2)
PYEOF
        printf "JSON rapor: %s\n" "$JSON_FILE"
        rm -f "$TSV_FINDINGS"
    else
        printf "%sUyarı: python3 yok, JSON üretilemedi.%s\n" "$Y" "$NC"
    fi
fi

# Çıkış kodu
if (( ERR_COUNT > 0 )); then
    exit 1
elif (( WARN_COUNT > 0 && STRICT == 1 )); then
    exit 1
else
    exit 0
fi
