# clean base image containing only comfyui, comfy-cli and comfyui-manager
FROM runpod/worker-comfyui:5.5.1-base

ENV DEBIAN_FRONTEND=noninteractive

# install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    git \
    curl \
    ca-certificates \
    libgl1 \
    libglib2.0-0 \
    libxcb1 \
    libx11-6 \
    libxext6 \
    libsm6 \
    && rm -rf /var/lib/apt/lists/*

# install custom nodes that work through Comfy Registry
RUN comfy node install comfyui-videohelpersuite
RUN comfy node install comfyui-frame-interpolation
RUN comfy node install video-output-bridge

# install ReActor manually
# DO NOT use: RUN comfy node install comfyui-reactor
RUN rm -rf /comfyui/custom_nodes/ComfyUI-ReActor \
    && git clone --depth=1 https://github.com/Gourieff/ComfyUI-ReActor /comfyui/custom_nodes/ComfyUI-ReActor \
    && python3 -m pip install --no-cache-dir --upgrade pip setuptools wheel importlib-metadata \
    && python3 -m pip install --no-cache-dir -r /comfyui/custom_nodes/ComfyUI-ReActor/requirements.txt \
    && python3 /comfyui/custom_nodes/ComfyUI-ReActor/install.py

# fail the build if ReActorFaceSwap is not actually present
RUN test -f /comfyui/custom_nodes/ComfyUI-ReActor/nodes.py \
    && grep -q "ReActorFaceSwap" /comfyui/custom_nodes/ComfyUI-ReActor/nodes.py

# create model downloader script
RUN cat > /download_models.sh <<'EOF'
#!/usr/bin/env bash
set -e

download_if_missing() {
  URL="$1"
  OUT="$2"
  MIN_SIZE_MB="$3"

  if [ -f "$OUT" ]; then
    SIZE_BYTES=$(stat -c%s "$OUT" || echo 0)
    MIN_BYTES=$((MIN_SIZE_MB * 1024 * 1024))

    if [ "$SIZE_BYTES" -ge "$MIN_BYTES" ]; then
      echo "[models] exists: $OUT"
      return 0
    fi

    echo "[models] file too small, re-downloading: $OUT"
    rm -f "$OUT"
  fi

  echo "[models] downloading: $OUT"
  mkdir -p "$(dirname "$OUT")"

  curl -fL \
    --retry 8 \
    --retry-delay 5 \
    --retry-all-errors \
    --connect-timeout 30 \
    -o "$OUT.tmp" \
    "$URL"

  SIZE_BYTES=$(stat -c%s "$OUT.tmp" || echo 0)
  MIN_BYTES=$((MIN_SIZE_MB * 1024 * 1024))

  if [ "$SIZE_BYTES" -lt "$MIN_BYTES" ]; then
    echo "[models] ERROR: downloaded file is too small: $OUT.tmp"
    echo "[models] Size bytes: $SIZE_BYTES"
    exit 1
  fi

  mv "$OUT.tmp" "$OUT"
  echo "[models] done: $OUT"
}

# ReActor HyperSwap model
download_if_missing \
  "https://huggingface.co/facefusion/models-3.3.0/resolve/main/hyperswap_1a_256.onnx" \
  "/comfyui/models/hyperswap/hyperswap_1a_256.onnx" \
  100

# ReActor face restoration model
download_if_missing \
  "https://huggingface.co/datasets/Gourieff/ReActor/resolve/main/models/facerestore_models/codeformer-v0.1.0.pth" \
  "/comfyui/models/facerestore_models/codeformer-v0.1.0.pth" \
  100

# YOLOv5l face detection helper
download_if_missing \
  "https://huggingface.co/martintomov/comfy/resolve/main/facedetection/yolov5l-face.pth" \
  "/comfyui/models/facedetection/yolov5l-face.pth" \
  20

# face parsing helper
download_if_missing \
  "https://huggingface.co/gmk123/GFPGAN/resolve/main/parsing_parsenet.pth" \
  "/comfyui/models/facedetection/parsing_parsenet.pth" \
  5

# FILM VFI model
download_if_missing \
  "https://huggingface.co/nguu/film-pytorch/resolve/887b2c42bebcb323baf6c3b6d59304135699b575/film_net_fp32.pt" \
  "/comfyui/custom_nodes/ComfyUI-Frame-Interpolation/ckpts/film/film_net_fp32.pt" \
  20
EOF

RUN chmod +x /download_models.sh

# start normal RunPod ComfyUI worker after model setup
RUN cat > /start_with_models.sh <<'EOF'
#!/usr/bin/env bash
set -e

echo "[startup] checking/downloading required models..."
/download_models.sh

echo "[startup] starting RunPod ComfyUI worker..."
exec /start.sh
EOF

RUN chmod +x /start_with_models.sh

CMD ["/start_with_models.sh"]
