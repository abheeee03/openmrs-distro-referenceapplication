#!/usr/bin/env bash
# Fail if the SPA manifest still contains the literal $SPA_PATH when the
# client asks for gzip, brotli, or no compression.
#
# Default mode starts nginx with frontend/nginx.conf and frontend/startup.sh
# and a fixture that includes stale .gz/.br siblings, the same shape openmrs
# build writes into the image. CHECK_BASE_URL points the same assertions at a
# running gateway, for example http://localhost/openmrs/spa.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ACCEPT_ENCODINGS=("identity" "gzip" "br" "gzip, br")

if ! command -v brotli >/dev/null 2>&1; then
  echo "brotli is required (the brotli CLI)" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required" >&2
  exit 1
fi

DECODED=""
FAILS=0

fail() {
  echo "FAIL: $*" >&2
  FAILS=$((FAILS + 1))
}

fetch_decoded() {
  local url="$1" accept="$2" body headers code enc
  body="$(mktemp)"
  headers="$(mktemp)"
  code="$(
    curl -sS -D "$headers" -o "$body" --max-time 20 \
      -H "Accept-Encoding: $accept" \
      -w '%{http_code}' \
      "$url" || true
  )"
  if [[ "$code" != "200" ]]; then
    echo "HTTP ${code:-curl error} for $url (Accept-Encoding: $accept)" >&2
    cat "$headers" >&2 || true
    rm -f "$body" "$headers"
    return 1
  fi
  # macOS awk has no IGNORECASE; lowercase the header block first.
  enc="$(tr 'A-Z' 'a-z' < "$headers" | tr -d '\r' | awk '/^content-encoding:/ {print $2; exit}')"
  ENC="$enc"
  : >"$DECODED"
  case "$enc" in
    "") cp "$body" "$DECODED" ;;
    gzip) gzip -dc "$body" >"$DECODED" || return 1 ;;
    br) brotli -d -c "$body" >"$DECODED" || return 1 ;;
    *)
      echo "unexpected Content-Encoding '$enc' for $url" >&2
      rm -f "$body" "$headers"
      return 1
      ;;
  esac
  rm -f "$body" "$headers"
}

assert_no_placeholder() {
  local label="$1"
  if grep -q '\$SPA_PATH' "$DECODED"; then
    fail "$label still contains \$SPA_PATH"
    sed -n '1,20p' "$DECODED" >&2
    return
  fi
  echo "ok  $label"
}

assert_icons() {
  local label="$1" origin="$2" spa_path="$3" mode="$4"
  local srcs src target
  if ! srcs="$(python3 - "$DECODED" "$spa_path" "$mode" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
spa = sys.argv[2]
mode = sys.argv[3]
icons = doc.get("icons") or []
if not icons:
    sys.exit("manifest has no icons")
for icon in icons:
    src = icon.get("src") or ""
    if "$SPA_PATH" in src:
        sys.exit("icon src still contains $SPA_PATH: " + src)
    if mode == "frontend":
        if spa:
            prefix = spa.rstrip("/")
            if not src.startswith(prefix + "/"):
                sys.exit("icon %s is not under %s" % (src, prefix))
            print(src[len(prefix):])
        else:
            if not src.startswith("/"):
                sys.exit("icon path is not root-absolute: " + src)
            print(src)
    else:
        print(src)
PY
  )"; then
    fail "$label icon list ($srcs)"
    return
  fi
  while IFS= read -r src; do
    [[ -n "$src" ]] || continue
    if [[ "$src" == http://* || "$src" == https://* ]]; then
      target="$src"
    elif [[ "$src" == /* ]]; then
      target="${origin}${src}"
    else
      fail "$label icon is not a usable URL: $src"
      continue
    fi
    code="$(curl -sS -o /dev/null --max-time 20 -w '%{http_code}' "$target" || true)"
    if [[ "$code" != "200" ]]; then
      fail "$label icon $target returned HTTP ${code:-curl error}"
    else
      echo "ok  $label icon $target"
    fi
  done <<<"$srcs"
}

expected_content_encoding() {
  case "$1" in
    identity) printf '' ;;
    gzip) printf 'gzip' ;;
    br) printf 'br' ;;
    "gzip, br") printf 'br' ;;
    *) printf '%s' "$1" ;;
  esac
}

check_manifest_url() {
  local manifest_url="$1" origin="$2" spa_path="$3" mode="$4" accept want
  for accept in "${ACCEPT_ENCODINGS[@]}"; do
    if ! fetch_decoded "$manifest_url" "$accept"; then
      fail "manifest $manifest_url Accept-Encoding: $accept"
      continue
    fi
    if [[ "$mode" == "frontend" ]]; then
      want="$(expected_content_encoding "$accept")"
      if [[ "$ENC" != "$want" ]]; then
        fail "manifest Accept-Encoding: $accept served Content-Encoding '${ENC:-<none>}'"
      fi
    fi
    assert_no_placeholder "manifest Accept-Encoding: $accept"
  done
  if ! fetch_decoded "$manifest_url" "identity"; then
    fail "manifest $manifest_url could not be read for icon checks"
    return
  fi
  assert_icons "manifest" "$origin" "$spa_path" "$mode"
}

check_text_url() {
  local url="$1" accept="$2" expect="$3"
  if ! fetch_decoded "$url" "$accept"; then
    fail "$url Accept-Encoding: $accept"
    return
  fi
  assert_no_placeholder "$url Accept-Encoding: $accept"
  if [[ -n "$expect" ]] && ! grep -q -F "$expect" "$DECODED"; then
    fail "$url does not contain $expect"
    sed -n '1,20p' "$DECODED" >&2
  fi
}

check_live() {
  local base="${1%/}" page manifest_path manifest_url origin
  local attempt=0
  while (( attempt < 30 )); do
    if curl -sf --max-time 10 -o /dev/null "$base/index.html"; then
      break
    fi
    attempt=$((attempt + 1))
    sleep 2
  done
  page="$(mktemp)"
  curl -fsS --max-time 20 -o "$page" "$base/index.html"
  manifest_path="$(python3 - "$page" <<'PY'
import re, sys
html = open(sys.argv[1], encoding="utf-8", errors="replace").read()
match = re.search(r'href="([^"]*manifest\.[^"]+\.json)"', html)
if not match:
    sys.exit("index.html has no manifest href")
print(match.group(1))
PY
)"
  rm -f "$page"
  origin="$(python3 - "$base" <<'PY'
import sys
from urllib.parse import urlsplit
parts = urlsplit(sys.argv[1])
print("%s://%s" % (parts.scheme, parts.netloc))
PY
)"
  if [[ "$manifest_path" == http://* || "$manifest_path" == https://* ]]; then
    manifest_url="$manifest_path"
  elif [[ "$manifest_path" == /* ]]; then
    manifest_url="${origin}${manifest_path}"
  else
    manifest_url="${base}/${manifest_path}"
  fi
  echo "checking $manifest_url"
  check_manifest_url "$manifest_url" "$origin" "" "gateway"
  check_text_url "$base/index.html" "gzip, br" ""
  # This build does not always emit service-worker.js. startup.sh still
  # rewrites it when the file is there; the fixture covers that case.
  sw_code="$(curl -sS -o /dev/null --max-time 20 -w '%{http_code}' "$base/service-worker.js" || true)"
  if [[ "$sw_code" != "404" ]]; then
    check_text_url "$base/service-worker.js" "gzip, br" ""
  fi
}

prepare_image() {
  if docker run --rm --entrypoint sh openmrs-manifest-encoding-check:local \
    -c 'command -v brotli >/dev/null && command -v sponge >/dev/null'; then
    return 0
  fi
  local build_dir
  build_dir="$(mktemp -d)"
  cat >"$build_dir/Dockerfile" <<'EOF'
FROM nginx:1.31-alpine
RUN apk add --no-cache moreutils brotli
EOF
  docker build -t openmrs-manifest-encoding-check:local "$build_dir"
  rm -rf "$build_dir"
}

prepare_template() {
  local template="$1" manifest
  mkdir -p "$template"
  python3 - "$template/icon_144.png" "$template/icon_512.png" <<'PY'
import pathlib, sys
png = bytes.fromhex(
    "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c489"
    "0000000a49444154789c63000100000500010d0a2db40000000049454e44ae426082"
)
for path in sys.argv[1:]:
    pathlib.Path(path).write_bytes(png)
PY
  cat >"$template/index.html" <<'EOF'
<!doctype html>
<html><head>
<link rel="manifest" href="/manifest.fixture.json" />
</head><body>
<script src="$SPA_PATH/importmap.json"></script>
<script>window.openmrsConfigUrls = ["$SPA_CONFIG_URLS"];</script>
</body></html>
EOF
  cat >"$template/service-worker.js" <<'EOF'
const importMapUrl = "$SPA_PATH/importmap.json";
const apiUrl = "$API_URL";
EOF
  cat >"$template/manifest.fixture.json" <<'EOF'
{
  "start_url": "$SPA_PATH/",
  "icons": [
    {"src": "$SPA_PATH/icon_144.png", "sizes": "144x144", "type": "image/png"},
    {"src": "$SPA_PATH/icon_512.png", "sizes": "512x512", "type": "image/png"}
  ]
}
EOF
  manifest="$template/manifest.fixture.json"
  gzip -n -c "$manifest" >"${manifest}.gz"
  gzip -n -c "$template/index.html" >"$template/index.html.gz"
  gzip -n -c "$template/service-worker.js" >"$template/service-worker.js.gz"
  brotli -c "$manifest" >"${manifest}.br"
  brotli -c "$template/index.html" >"$template/index.html.br"
  brotli -c "$template/service-worker.js" >"$template/service-worker.js.br"
}

run_case() {
  local name="$1" spa_path="$2" importmap_url="$3"
  shift 3
  local html="$WORK/html-$name" cid port base expect
  rm -rf "$html"
  cp -R "$TEMPLATE" "$html"
  cid="$(
    docker run -d --name "omrs-manifest-${name}-$$" \
      -p 127.0.0.1::80 \
      -v "$ROOT/frontend/startup.sh:/usr/local/bin/startup.sh:ro" \
      -v "$ROOT/frontend/nginx.conf:/etc/nginx/nginx.conf:ro" \
      -v "$html:/usr/share/nginx/html" \
      "$@" \
      openmrs-manifest-encoding-check:local \
      sh /usr/local/bin/startup.sh
  )"
  CIDS+=("$cid")
  port="$(docker port "$cid" 80/tcp | awk -F: 'NR==1 {print $NF}')"
  base="http://127.0.0.1:${port}"
  echo
  echo "== $name =="
  local attempt=0 ready=0
  while (( attempt < 40 )); do
    if curl -sf --max-time 2 -o /dev/null "$base/manifest.fixture.json"; then
      ready=1
      break
    fi
    if [[ "$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null || echo false)" != "true" ]]; then
      docker logs "$cid" >&2 || true
      fail "$name container exited before nginx accepted connections"
      return
    fi
    attempt=$((attempt + 1))
    sleep 0.5
  done
  if (( ready == 0 )); then
    docker logs "$cid" >&2 || true
    fail "$name did not become ready"
    return
  fi
  check_manifest_url "$base/manifest.fixture.json" "$base" "$spa_path" "frontend"
  if [[ -n "$importmap_url" ]]; then
    expect="$importmap_url"
  elif [[ -n "$spa_path" ]]; then
    expect="$spa_path/importmap.json"
  else
    expect="/importmap.json"
  fi
  check_text_url "$base/" "gzip, br" "$expect"
  check_text_url "$base/service-worker.js" "br" "$expect"
}

cleanup() {
  local cid
  if [[ "${#CIDS[@]}" -gt 0 ]]; then
    for cid in "${CIDS[@]}"; do
      docker rm -f "$cid" >/dev/null 2>&1 || true
    done
  fi
  if [[ -n "${WORK:-}" ]]; then
    rm -rf "$WORK"
  fi
}

if [[ -n "${CHECK_BASE_URL:-}" ]]; then
  DECODED="$(mktemp)"
  trap 'rm -f "$DECODED"' EXIT
  check_live "$CHECK_BASE_URL"
else
  if ! command -v docker >/dev/null 2>&1; then
    echo "docker is required to run the fixture check" >&2
    exit 1
  fi
  CIDS=()
  WORK="$(mktemp -d "$ROOT/.manifest-check.XXXXXX")"
  TEMPLATE="$WORK/template"
  DECODED="$WORK/decoded"
  trap cleanup EXIT
  prepare_image
  prepare_template "$TEMPLATE"
  run_case with_spa_path "/openmrs/spa" "" \
    -e SPA_PATH=/openmrs/spa \
    -e API_URL=/openmrs
  run_case without_spa_or_importmap "" "" \
    -e API_URL=/openmrs
  run_case with_spa_path_and_importmap "/openmrs/spa" "https://cdn.example/importmap.json" \
    -e SPA_PATH=/openmrs/spa \
    -e IMPORTMAP_URL=https://cdn.example/importmap.json \
    -e API_URL=/openmrs
  run_case importmap_without_spa_path "" "https://cdn.example/importmap.json" \
    -e IMPORTMAP_URL=https://cdn.example/importmap.json \
    -e API_URL=/openmrs
fi

if [[ "$FAILS" -gt 0 ]]; then
  echo "$FAILS check(s) failed" >&2
  exit 1
fi
echo "manifest encodings have no SPA_PATH placeholders"
