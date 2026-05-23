#!/bin/bash
# Build HuggingFace Tokenizers C FFI wrapper library
# Produces: f_hydra/lib/libcj_tokenizers_c.so
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "[1/3] Cloning tokenizers from mirror..."
if [ ! -d /tmp/tokenizers ]; then
    git clone https://gitcode.com/runningW/tokenizers.git /tmp/tokenizers
else
    echo "  Already cloned, skipping"
fi

echo "[2/3] Building C wrapper..."
cat > /tmp/cj_tokenizers_c/Cargo.toml << 'EOF'
[package]
name = "cj_tokenizers_c"
version = "0.1.0"
edition = "2021"
[lib]
crate-type = ["cdylib"]
[dependencies]
tokenizers = { path = "/tmp/tokenizers/tokenizers" }
EOF

mkdir -p /tmp/cj_tokenizers_c/src
cp "$SCRIPT_DIR/../src/ffi/tokenizers_bridge.rs" /tmp/cj_tokenizers_c/src/lib.rs 2>/dev/null || \
    echo "ERROR: tokenizers_bridge.rs not found, building with default"

cd /tmp/cj_tokenizers_c && cargo build --release

echo "[3/3] Installing to $PROJECT_DIR/lib/"
cp /tmp/cj_tokenizers_c/target/release/libcj_tokenizers_c.so "$PROJECT_DIR/lib/"

echo "Done! libcj_tokenizers_c.so ready at $PROJECT_DIR/lib/"
echo "Exported symbols:"
nm -D "$PROJECT_DIR/lib/libcj_tokenizers_c.so" | grep ' T '
