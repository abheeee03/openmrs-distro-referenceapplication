#!/bin/sh
set -e

# if we are using the $IMPORTMAP_URL environment variable, we have to make this useful,
# so we change "importmap.json" into "$IMPORTMAP_URL" allowing it to be changed by envsubst
if [ -n "${IMPORTMAP_URL}" ]; then
  # The assembled page quotes the literal $SPA_PATH/importmap.json. Swap that
  # for $IMPORTMAP_URL before envsubst. Match either quote character; the old
  # pattern looked for the two characters "|", so the URL was never written.
  for target in /usr/share/nginx/html/index.html /usr/share/nginx/html/service-worker.js; do
    [ -f "$target" ] || continue
    sed -i \
      -e 's/\("\|'\''\)$SPA_PATH\/importmap.json\("\|'\''\)/\1$IMPORTMAP_URL\1/g' \
      -e 's/\("\|'\''\)importmap.json\("\|'\''\)/\1$IMPORTMAP_URL\1/g' \
      "$target"
  done
fi

# setting the config urls to "" causes an error reported in the console, so if we aren't using
# the SPA_CONFIG_URLS, we remove it from the source, leaving config urls as []
if [ -z "$SPA_CONFIG_URLS" ]; then
  sed -i -e 's/"$SPA_CONFIG_URLS"//' "/usr/share/nginx/html/index.html"
# otherwise convert the URLs into a Javascript list
# we support two formats, a comma-separated list or a space separated list
else
  old_IFS="$IFS"
  if echo "$SPA_CONFIG_URLS" | grep , >/dev/null; then
    IFS=","
  fi

  CONFIG_URLS=
  for url in $SPA_CONFIG_URLS;
  do
    if [ -z "$CONFIG_URLS" ]; then
      CONFIG_URLS="\"${url}\""
    else
      CONFIG_URLS="$CONFIG_URLS,\"${url}\""
    fi
  done

  IFS="$old_IFS"
  export SPA_CONFIG_URLS=$CONFIG_URLS
  sed -i -e 's/"$SPA_CONFIG_URLS"/$SPA_CONFIG_URLS/' "/usr/share/nginx/html/index.html"
fi

SPA_DEFAULT_LOCALE=${SPA_DEFAULT_LOCALE:-en_GB}

# Substitute environment variables in the html file
# This allows us to override parts of the compiled file at runtime
if [ -f "/usr/share/nginx/html/index.html" ]; then
  envsubst '${IMPORTMAP_URL} ${SPA_PATH} ${API_URL} ${SPA_CONFIG_URLS} ${SPA_DEFAULT_LOCALE}' < "/usr/share/nginx/html/index.html" | sponge "/usr/share/nginx/html/index.html"
fi

if [ -f "/usr/share/nginx/html/service-worker.js" ]; then
  envsubst '${IMPORTMAP_URL} ${SPA_PATH} ${API_URL}' < "/usr/share/nginx/html/service-worker.js" | sponge "/usr/share/nginx/html/service-worker.js"
fi

for manifest in /usr/share/nginx/html/manifest.*.json; do
  break;
done

if [ -f "$manifest" ]; then
  envsubst '${IMPORTMAP_URL} ${SPA_PATH} ${API_URL}' < "$manifest" | sponge "$manifest"
fi

# The image build writes .gz and .br next to compressible files, and nginx
# serves those ahead of the plain file (see try_files $uri$enc_suffix in
# nginx.conf). Substitution above only rewrites the plain file, so refresh
# every file this script edits. index.html and service-worker.js are not
# served from those copies today; the manifest JSON is.
refresh_precompressed() {
  target="$1"
  [ -f "$target" ] || return 0
  rm -f "${target}.gz" "${target}.br"
  gzip -9 -c "$target" > "${target}.gz"
  if command -v brotli >/dev/null 2>&1; then
    brotli -q 11 -c "$target" > "${target}.br"
  fi
}

refresh_precompressed "/usr/share/nginx/html/index.html"
refresh_precompressed "/usr/share/nginx/html/service-worker.js"
if [ -f "$manifest" ]; then
  refresh_precompressed "$manifest"
fi

exec nginx -g "daemon off;"
