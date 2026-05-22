#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="${SCRIPT_DIR}/dist"
NGINX_VERSION="1.30.0"
WRK_VERSION="4.2.0"
PORT="8089"
THREADS="$(nproc)"

NGINX_URL="http://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz"
NGINX_SHA256="058188c64bf22baecaa72b809a6318a4f9ba623889c554feab03f7cb853ab31b"
WRK_URL="https://github.com/wg/wrk/archive/refs/tags/${WRK_VERSION}.tar.gz"
WRK_SHA256="e255f696bff6e329f5d19091da6b06164b8d59d62cb9e673625bdcd27fe7bdad"
TESTFILES_URL="http://www.phoronix-test-suite.com/benchmark-files/http-test-files-1.tar.xz"
TESTFILES_SHA256="9d6eace9544c59b910ea403a4693338efc12a6b0915fe227aed86c971b82d3dd"

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

check_sha256() {
    local file="$1" expected="$2"
    local actual
    actual="$(sha256sum "$file" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] || die "SHA256 mismatch for $file (got $actual, expected $expected)"
}

download() {
    local url="$1" dest="$2" sha256="$3"
    if [[ -f "$dest" ]]; then
        info "Already downloaded: $(basename "$dest"), verifying..."
        check_sha256 "$dest" "$sha256"
        return
    fi
    info "Downloading $(basename "$dest")..."
    curl -fL --progress-bar "$url" -o "${dest}.tmp"
    check_sha256 "${dest}.tmp" "$sha256"
    mv "${dest}.tmp" "$dest"
}

# -- Setup
mkdir -p "$DIST_DIR/downloads"

# -- Download
download "$NGINX_URL"     "$DIST_DIR/downloads/nginx-${NGINX_VERSION}.tar.gz"  "$NGINX_SHA256"
download "$WRK_URL"       "$DIST_DIR/downloads/wrk-${WRK_VERSION}.tar.gz"      "$WRK_SHA256"
download "$TESTFILES_URL" "$DIST_DIR/downloads/http-test-files-1.tar.xz"       "$TESTFILES_SHA256"

# -- Build nginx
info "Building nginx ${NGINX_VERSION}..."
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

tar -xf "$DIST_DIR/downloads/nginx-${NGINX_VERSION}.tar.gz" -C "$BUILD_DIR"
pushd "$BUILD_DIR/nginx-${NGINX_VERSION}" > /dev/null
CFLAGS="-Wno-error -O3 -march=native" CXXFLAGS="-Wno-error -O3 -march=native" \
    ./configure \
        --prefix="$DIST_DIR/nginx" \
        --without-http_rewrite_module \
        --without-http-cache \
        --with-http_ssl_module \
        --error-log-path=logs/error.log \
        --pid-path=logs/nginx.pid
make -j "$THREADS"
make install
popd > /dev/null

# -- Build wrk
info "Building wrk ${WRK_VERSION}..."
tar -xf "$DIST_DIR/downloads/wrk-${WRK_VERSION}.tar.gz" -C "$BUILD_DIR"
pushd "$BUILD_DIR/wrk-${WRK_VERSION}" > /dev/null
make -j "$THREADS"
cp wrk "$DIST_DIR/wrk"
popd > /dev/null

# -- TLS certificate
info "Generating self-signed TLS certificate (RSA 4096)..."
openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 \
    -subj "/C=US/ST=Denial/L=Chicago/O=Dis/CN=127.0.0.1" \
    -keyout "$DIST_DIR/localhost.key" \
    -out    "$DIST_DIR/localhost.cert" 2>/dev/null
chmod 600 "$DIST_DIR/localhost.key"

# -- nginx.conf
info "Writing nginx.conf..."
cat > "$DIST_DIR/nginx/conf/nginx.conf" <<EOF
worker_processes auto;
error_log  logs/error.log;
pid        logs/nginx.pid;

events {
    worker_connections 10240;
}

http {
    include      mime.types;
    default_type application/octet-stream;
    sendfile     on;
    access_log   off;

    keepalive_timeout 65;

    server {
        listen      ${PORT} ssl;
        server_name 127.0.0.1;

        ssl_certificate     ${DIST_DIR}/localhost.cert;
        ssl_certificate_key ${DIST_DIR}/localhost.key;
        ssl_ciphers         HIGH:!aNULL:!MD5;

        root  html;
        index index.html test.html;
    }
}
EOF

# -- Test content
info "Installing test HTML files..."
tar -xf "$DIST_DIR/downloads/http-test-files-1.tar.xz" -C "$BUILD_DIR"
mkdir -p "$DIST_DIR/nginx/html"
cp -r "$BUILD_DIR/http-test-files/." "$DIST_DIR/nginx/html/"

info "Installation complete."
echo ""
echo "  nginx binary : $DIST_DIR/nginx/sbin/nginx"
echo "  wrk binary   : $DIST_DIR/wrk"
echo "  nginx config : $DIST_DIR/nginx/conf/nginx.conf"
echo "  serving on   : https://127.0.0.1:${PORT}/test.html"
echo ""
echo "Usage:"
echo "  ./start.sh          # start nginx"
echo "  ./bench.sh          # run benchmark with defaults"
echo "  ./bench.sh -c 500   # 500 concurrent connections"
echo "  ./stop.sh           # stop nginx"
