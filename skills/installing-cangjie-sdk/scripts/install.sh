#!/usr/bin/env bash
# install.sh - Cangjie SDK/stdx/docs installer. Run INSIDE WSL Ubuntu.
# Subcommands:
#   nightly                      install latest complete nightly_build release (sdk+stdx+docs+stdx-docs)
#   official <version> [arch]    install official SDK from cangjie-lang.cn (arch default: auto-detect)
#   setenv <sdk_ver> <stdx_ver>  rewrite the 'cj env' line at the end of cangjie.sh
#   versions                     report latest NIGHTLY / STS / LTS full versions
#   set-root <install-root>      persist the install root to config.env (once, on first use)
#
# Install root: read from <skill>/config.env (CANGJIE_ROOT=...). If unset the
# script refuses — the agent must ask the user for the root and persist it via
# 'set-root'. All paths below hang off CANGJIE_ROOT:
#   sdk       -> $CANGJIE_ROOT/cangjie-linux-bin/sdk/<ver>/   (archive deleted after extract, extracts to cangjie/)
#   stdx      -> $CANGJIE_ROOT/cangjie-linux-bin/stdx/<ver>/  (archive deleted after extract, extracts to linux_x86_64_cjnative/)
#   docs      -> $CANGJIE_ROOT/cangjie-doc/<ver>/
#   stdx-docs -> $CANGJIE_ROOT/cangjie-doc/stdx/<ver>/
#   <ver> = first [0-9]+(\.[0-9]+)+ match of the asset filename's version
#           (1.3.0-alpha.20261015001050.1 -> 1.3.0 ; 1.0.4.1 -> 1.0.4.1 ; 1.2.0 -> 1.2.0)
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd -P)
CONF=$SCRIPT_DIR/../config.env
if [[ -f $CONF ]]; then
  # shellcheck source=/dev/null
  source "$CONF"
fi
CANGJIE_ROOT=${CANGJIE_ROOT:-}
RELEASES_API=https://gitcode.com/api/v5/repos/Cangjie/nightly_build/releases
SITE=https://cangjie-lang.cn

log() { printf '[install.sh] %s\n' "$*" >&2; }
die() { printf '[install.sh] ERROR: %s\n' "$*" >&2; exit 1; }
dry() { [[ ${CJ_DRY_RUN:-0} = 1 ]]; }

if [[ ${1:-} != set-root ]]; then
  [[ -n $CANGJIE_ROOT ]] || die "install root not configured. Ask the user for the install root (absolute POSIX path visible from WSL), persist it once with: install.sh set-root <path> - then rerun. Config lives in $CONF."
fi
BIN_ROOT=$CANGJIE_ROOT/cangjie-linux-bin
DOC_ROOT=$CANGJIE_ROOT/cangjie-doc
CANGJIE_SH=$CANGJIE_ROOT/cangjie.sh

numeric_ver() { printf '%s' "$1" | grep -oE '[0-9]+(\.[0-9]+)+' | head -n1; }

detect_arch() {
  case "$(uname -m)" in
    x86_64)  echo x64 ;;
    aarch64) echo aarch64 ;;
    *) die "unsupported arch: $(uname -m)" ;;
  esac
}

fetch() {
  if command -v curl >/dev/null 2>&1; then curl -fsSL --retry 3 "$1"
  else wget -qO- "$1"; fi
}

download() {
  if dry; then echo "[dry-run] download $1 -> $2"; return 0; fi
  if command -v curl >/dev/null 2>&1; then curl -fL --retry 3 --progress-bar -o "$2" "$1"
  else wget -q --show-progress -O "$2" "$1"; fi
}

extract_archive() {
  local archive=$1 dest=$2
  mkdir -p "$dest"
  if dry; then echo "[dry-run] extract $archive -> $dest"; return 0; fi
  case "$archive" in
    *.tar.gz|*.tgz) tar -xzf "$archive" -C "$dest" ;;
    *.zip)
      # Permission-preserving zip extraction (plain `python3 -m zipfile` loses exec bits).
      python3 - "$archive" "$dest" <<'PY'
import os, sys, zipfile
archive, dest = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(archive) as z:
    for info in z.infolist():
        target = z.extract(info, dest)
        perm = (info.external_attr >> 16) & 0o7777
        if perm:
            os.chmod(target, perm)
PY
      ;;
    *) die "unknown archive type: $archive" ;;
  esac
}

clean_old_archives() { # keep only the archive just installed
  local dest=$1 keep=$2 f
  find "$dest" -maxdepth 1 -type f \( -name 'cangjie-*.tar.gz' -o -name 'cangjie-*.zip' \) ! -name "$keep" -print0 |
    while IFS= read -r -d '' f; do rm -f -- "$f"; log "removed old archive: $f"; done
}

install_asset() { # install_asset <kind> <url>; echoes "<kind> <ver> <dest> installed|skip"
  local kind=$1 url=$2 name base ver dest marker
  name=$(printf '%s' "$url" | sed -n 's/.*[?&]fileName=\([^&]*\).*/\1/p')
  [[ -n ${name:-} ]] || name=$(basename "${url%%\?*}")
  case $kind in
    sdk)      base=$BIN_ROOT/sdk ;;
    stdx)     base=$BIN_ROOT/stdx ;;
    docs)     base=$DOC_ROOT ;;
    stdxdocs) base=$DOC_ROOT/stdx ;;
    *) die "unknown kind: $kind" ;;
  esac
  ver=$(numeric_ver "$name" || true)
  [[ -n ${ver:-} ]] || die "cannot derive numeric version from $name"
  dest=$base/$ver
  marker=$dest/.installed-$name
  mkdir -p "$dest"
  if [[ -f $marker ]]; then
    log "[$kind] $name already installed at $dest - skip"
    echo "$kind $ver $dest skip"
    return 0
  fi
  log "[$kind] downloading $url"
  download "$url" "$dest/$name"
  log "[$kind] extracting into $dest"
  extract_archive "$dest/$name" "$dest"
  if dry; then
    echo "$kind $ver $dest DRYRUN"
    return 0
  fi
  touch "$marker"
  rm -f "$dest/$name"
  log "[$kind] removed archive $dest/$name"
  clean_old_archives "$dest" "$name"
  echo "$kind $ver $dest installed"
}

cmd_nightly() {
  local arch; arch=$(detect_arch)
  command -v python3 >/dev/null 2>&1 || die "python3 not found in WSL distro"
  local tmp; tmp=$(mktemp /tmp/cj-nightly.XXXXXX)
  log "arch=$arch; querying nightly releases (direction=desc is REQUIRED)..."
  fetch "$RELEASES_API?per_page=30&direction=desc" > "$tmp.json" || die "cannot query $RELEASES_API"
  local picks tag summary="" out kind url
  picks=$(python3 - "$arch" "$tmp.json" <<'PY'
import json, sys
arch, path = sys.argv[1], sys.argv[2]
rels = json.load(open(path, encoding='utf-8'))
def pick(names, prefix, suffix, exclude=()):
    for n in names:
        if n.startswith(prefix) and n.endswith(suffix) and not any(x in n for x in exclude):
            return n
    return None
for rel in rels:
    assets = {a['name']: a['browser_download_url'] for a in rel.get('assets', []) if a.get('type') != 'source'}
    got = {
        'sdk':      pick(assets, f'cangjie-sdk-linux-{arch}-', '.tar.gz', ('-sanitizer', '-android', '-ohos')),
        'stdx':     pick(assets, f'cangjie-stdx-linux-{arch}-', '.zip'),
        'docs':     pick(assets, 'cangjie-docs-html-', '.tar.gz'),
        'stdxdocs': pick(assets, 'cangjie-stdx-docs-html-', '.tar.gz'),
    }
    if all(got.values()):
        print(f'# release {rel["tag_name"]}')
        for k in ('sdk', 'stdx', 'docs', 'stdxdocs'):
            print(f'{k}\t{assets[got[k]]}')
        sys.exit(0)
sys.exit(2)
PY
) || die "no complete nightly release found in newest 30 (some releases are partial) - check $RELEASES_API"
  tag=$(printf '%s\n' "$picks" | sed -n 's/^# release //p')
  log "picked release: $tag"
  while IFS=$'\t' read -r kind url; do
    out=$(install_asset "$kind" "$url")
    printf '%s\n' "$out"
    summary+="$out"$'\n'
  done < <(printf '%s\n' "$picks" | grep -v '^#')
  local sdk_ver stdx_ver
  sdk_ver=$(printf '%s' "$summary" | awk '$1=="sdk"{print $2}')
  stdx_ver=$(printf '%s' "$summary" | awk '$1=="stdx"{print $2}')
  printf 'INSTALLED_TAG=%s\nSDK_VER=%s\nSTDX_VER=%s\nSUGGESTED_ENV=cj env %s %s\n' "$tag" "$sdk_ver" "$stdx_ver" "$sdk_ver" "$stdx_ver"
  rm -f "$tmp.json"
}

cmd_official() {
  local version=${1:?usage: install.sh official <version> [arch]}
  local arch=${2:-$(detect_arch)}
  command -v python3 >/dev/null 2>&1 || die "python3 not found in WSL distro"
  log "official SDK $version arch=$arch"
  local html js_url js path esc out ver
  html=$(fetch "$SITE/download/$version") || die "cannot fetch $SITE/download/$version"
  js_url=$(printf '%s\n' "$html" | grep -oE '(https?:)?//csdnimg\.cn/release/devpress-cangjie/public/js/chunk/organization/download/version\.[0-9a-f]+\.js' | head -n1 || true)
  [[ -n ${js_url:-} ]] || die "download JS chunk not found on $SITE/download/$version (page layout changed?)"
  case $js_url in //*) js_url=https:$js_url ;; esac
  log "js chunk: $js_url"
  js=$(fetch "$js_url") || die "cannot fetch js chunk"
  esc=${version//./\\.}
  path=$(printf '%s\n' "$js" | grep -oE "/v1/files/auth/downLoad\?nsId=[0-9]+&fileName=cangjie-sdk-linux-$arch-$esc\.tar\.gz&objectKey=[0-9a-f]+" | head -n1 || true)
  [[ -n ${path:-} ]] || die "downLoad path for cangjie-sdk-linux-$arch-$version.tar.gz not found in JS chunk"
  out=$(install_asset sdk "$SITE$path")
  printf '%s\n' "$out"
  ver=$(printf '%s' "$out" | awk '$1=="sdk"{print $2}')
  printf 'SDK_VER=%s\n' "$ver"
  printf 'NOTE=cangjie.sh needs TWO versions: cj env %s <stdx_ver> - ask the user for stdx_ver\n' "$ver"
}

cmd_setenv() {
  local sdk_ver=${1:?usage: install.sh setenv <sdk_ver> <stdx_ver>}
  local stdx_ver=${2:?usage: install.sh setenv <sdk_ver> <stdx_ver>}
  [[ -f $CANGJIE_SH ]] || die "$CANGJIE_SH not found"
  local bak="/tmp/cangjie.sh.bak.$(date +%Y%m%d%H%M%S)"
  if dry; then
    log "[dry-run] would rewrite last 'cj env' line of $CANGJIE_SH to: cj env $sdk_ver $stdx_ver"
    return 0
  fi
  cp "$CANGJIE_SH" "$bak"
  python3 - "$CANGJIE_SH" "$sdk_ver" "$stdx_ver" <<'PY'
import re, sys
path, sdk, stdx = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path, encoding='utf-8').read().splitlines(keepends=True)
idx = next((i for i in range(len(lines) - 1, -1, -1) if lines[i].strip()), None)
if idx is None:
    sys.exit("cangjie.sh is empty - refusing to edit")
if not re.match(r'\s*cj\s+env\s+\S+\s+\S+', lines[idx]):
    sys.exit(f"last non-empty line is not 'cj env <sdk> <stdx>': {lines[idx]!r} - refusing to edit")
old = lines[idx].rstrip('\r\n')
lines[idx] = f'cj env {sdk} {stdx}\n'
open(path, 'w', encoding='utf-8', newline='').writelines(lines)
print(f'[install.sh] cangjie.sh: {old!r} -> cj env {sdk} {stdx}')
PY
  log "backup: $bak"
}

channel_link_ver() { # channel_link_ver <html> <CHANNEL> - version behind the channel card's 即刻下载 link
  printf '%s' "$1" | grep -oE "$2 Version</div>.{0,400}" | grep -oE 'href="/download/[0-9][0-9A-Za-z.]*"' | head -n1 | sed 's|href="/download/||; s|"$||; s|"||g'
}

selector_ver() { # selector_ver <versioned-page-html> <TYPE: STS|LTS> - first entry of the typed version dropdown
  printf '%s' "$1" | grep -oE '[0-9]+(\.[0-9]+)+(-[0-9A-Za-z.]+)? <em class="version-type">'"$2" | head -n1 | sed 's/ <em.*//'
}

cmd_versions() {
  command -v python3 >/dev/null 2>&1 || die "python3 not found in WSL distro"
  local tmp; tmp=$(mktemp /tmp/cj-versions.XXXXXX)
  log "querying latest nightly tag (regex \\d+(\\.\\d+)+-alpha.\\d{14})..."
  fetch "$RELEASES_API?per_page=10&direction=desc" > "$tmp.json" || die "cannot query $RELEASES_API"
  local nightly sts lts html sts0 lts0 sel_html
  nightly=$(python3 - "$tmp.json" <<'PY'
import json, re, sys
for r in json.load(open(sys.argv[1], encoding='utf-8')):
    if re.fullmatch(r'\d+(\.\d+)+-alpha.\d{14}', r['tag_name']):
        print(r['tag_name'])
        sys.exit(0)
sys.exit(2)
PY
) || die "no nightly tag matching \\d+(\\.\\d+)+-alpha.\\d{14} in newest 10 releases"
  html=$(fetch "$SITE/download") || die "cannot fetch $SITE/download"
  sts0=$(channel_link_ver "$html" STS)
  lts0=$(channel_link_ver "$html" LTS)
  [[ -n $sts0 && -n $lts0 ]] || die "channel cards on $SITE/download not parseable (page layout changed?)"
  sts=$sts0 lts=$lts0
  if sel_html=$(fetch "$SITE/download/$sts0"); then
    local s1 l1
    s1=$(selector_ver "$sel_html" STS)
    l1=$(selector_ver "$sel_html" LTS)
    if [[ -n $s1 && -n $l1 ]]; then
      sts=$s1 lts=$l1
      [[ $sts == "$sts0" && $lts == "$lts0" ]] || log "WARN: channel card ($sts0/$lts0) disagrees with version selector ($sts/$lts); reporting selector"
    fi
  fi
  printf 'NIGHTLY=%s\nSTS=%s\nLTS=%s\n' "$nightly" "$sts" "$lts"
  rm -f "$tmp.json"
}

cmd_set_root() {
  local root=${1:?usage: install.sh set-root <install-root>}
  case $root in
    /*) ;;
    *) die "install root must be an absolute POSIX path visible from WSL (e.g. /mnt/d/docs/work/cangjie); got '$root'" ;;
  esac
  if dry; then
    log "[dry-run] would persist install root '$root' to $CONF"
    return 0
  fi
  mkdir -p "$root" || die "cannot create $root"
  printf 'CANGJIE_ROOT=%s\n' "$root" > "$CONF"
  log "install root persisted to $CONF: $root"
}

case ${1:-} in
  nightly) shift; cmd_nightly "$@" ;;
  official) shift; cmd_official "$@" ;;
  setenv)  shift; cmd_setenv "$@" ;;
  versions) shift; cmd_versions "$@" ;;
  set-root) shift; cmd_set_root "$@" ;;
  *) die "usage: install.sh nightly | official <version> [arch] | setenv <sdk_ver> <stdx_ver> | versions | set-root <install-root>" ;;
esac
