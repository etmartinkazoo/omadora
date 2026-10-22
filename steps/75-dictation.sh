#!/usr/bin/env bash
# [user] Dictation: build whisper.cpp (local speech-to-text) and fetch its model
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

# Pinned whisper.cpp commit and models (SHA-256 from huggingface.co/ggerganov/whisper.cpp).
WHISPER_REPO="https://github.com/ggml-org/whisper.cpp"
WHISPER_COMMIT="0c7be69"
declare -A MODELS=(
    [base.en]=a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002
    [small.en]=c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d
    [large-v3-turbo-q5_0]=394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2
)
DATA="${XDG_DATA_HOME:-$HOME/.local/share}/omadora/whisper"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/omadora/dictation.conf"

# GPU (Vulkan) only when everything it needs is installed; otherwise the CPU.
vulkan=OFF
if [ "${OMADORA_WHISPER_VULKAN:-auto}" != off ] && command -v glslc >/dev/null \
    && [ -e /usr/include/vulkan/vulkan.h ] && [ -e /usr/include/spirv/unified1/spirv.hpp ]; then
    vulkan=ON
fi
STAMP="$DATA/.built-$WHISPER_COMMIT-vulkan-$vulkan"

for cmd in wtype pw-record; do
    command -v "$cmd" >/dev/null 2>&1 || die "missing command: $cmd (install the packages first: Dictation settings → Install, or the system-packages step)"
done

# The Atomic image ships whisper-cli prebuilt (atomic/Containerfile); a local
# build in ~/.local/bin, when there is one, takes precedence.
if [ -x /usr/bin/whisper-cli ] && [ ! -x "$HOME/.local/bin/whisper-cli" ]; then
    ok "whisper-cli comes with the omadora image"
elif [ ! -f "$STAMP" ] || [ ! -x "$HOME/.local/bin/whisper-cli" ]; then
    for cmd in git cmake g++; do
        command -v "$cmd" >/dev/null 2>&1 || die "missing command: $cmd (install the packages first: Dictation settings → Install, or the system-packages step)"
    done
    info "Building whisper.cpp ($WHISPER_COMMIT)"
    mkdir -p "$DATA"
    if [ ! -d "$DATA/src/.git" ]; then
        git clone --quiet --filter=blob:none "$WHISPER_REPO" "$DATA/src"
    fi
    git -C "$DATA/src" fetch --quiet origin
    git -C "$DATA/src" -c advice.detachedHead=false checkout --quiet "$WHISPER_COMMIT"
    rm -rf "$DATA/build"   # a fresh configure: the GPU setting may have changed
    cmake -S "$DATA/src" -B "$DATA/build" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
        -DGGML_NATIVE=ON -DGGML_VULKAN="$vulkan" -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=ON >/dev/null
    cmake --build "$DATA/build" -j"$(nproc)" --target whisper-cli >/dev/null
    install -Dm755 "$DATA/build/bin/whisper-cli" "$HOME/.local/bin/whisper-cli"
    rm -f "$DATA"/.built-*
    touch "$STAMP"
    echo "commit=$WHISPER_COMMIT vulkan=$vulkan" > "$DATA/build-info"
    ok "whisper-cli installed (GPU via Vulkan: $vulkan)"
else
    ok "whisper.cpp $WHISPER_COMMIT already built"
fi

# The configured model (small.en unless dictation.conf says otherwise).
model=small.en
if [ -f "$CONF" ]; then
    model=$(sed -n 's/^[[:space:]]*MODEL[[:space:]]*=[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p' "$CONF" | tail -1)
    model=${model:-small.en}
fi
if [ -n "${MODELS[$model]:-}" ]; then
    file="$DATA/models/ggml-$model.bin"
    if [ ! -f "$file" ]; then
        info "Downloading the $model speech model"
        mkdir -p "$DATA/models"
        download_verified "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$model.bin" \
            "${MODELS[$model]}" "$file.part"
        mv "$file.part" "$file"
    fi
    ok "model $model ready"
else
    info "dictation.conf names a custom model ($model); not downloading anything"
fi
info "Dictate with Super+Shift+D (hold to talk, or tap to start and tap again to stop)"
