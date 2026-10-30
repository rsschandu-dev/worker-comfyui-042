# syntax=docker/dockerfile:1
# RunPod ComfyUI worker with a newer ComfyUI than any published tag ships.
#
# runpod/worker-comfyui:5.10.0-base is built with ARG COMFYUI_VERSION=0.34.0,
# which predates the whole Qwen Image 2.1 architecture (comfy/ldm/qwen_image21,
# comfy/text_encoders/qwen_image21, the QwenImage21 latent format) and its nodes
# TextEncodeQwenImage21 and QwenImage21Cache. Qwen 2.1 graphs fail on the stock
# image with "Node 'QwenImage21Cache' not found".
#
# Derived from the same base so the registry only stores the delta layer.
FROM runpod/worker-comfyui:5.10.0-base

ARG COMFYUI_VERSION=0.42.0
ARG CUDA_VERSION_FOR_COMFY=12.8

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_PREFER_BINARY=1 \
    PIP_NO_INPUT=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:${PATH}"

# comfy-cli installs into its own workspace venv (/comfyui/.venv) while start.sh
# launches ComfyUI with /opt/venv, so the dependency set has to be mirrored into
# /opt/venv afterwards; skipping this makes ComfyUI crash at startup and surface
# as "server not reachable". Same reasoning as the upstream Dockerfile.
#
# extra_model_paths.yaml is what points ComfyUI at the network volume holding
# the models, so it must survive replacing the workspace.
RUN set -eu; \
    cp /comfyui/extra_model_paths.yaml /tmp/extra_model_paths.yaml; \
    rm -rf /comfyui; \
    /usr/bin/yes | comfy --workspace /comfyui install \
      --version "${COMFYUI_VERSION}" \
      --cuda-version "${CUDA_VERSION_FOR_COMFY}" \
      --nvidia; \
    cp /tmp/extra_model_paths.yaml /comfyui/extra_model_paths.yaml

# torch first, pinned to a cu128 build: ComfyUI declares a bare `torch`, and
# default PyPI now serves cu13 wheels needing driver 580+, while the hosts this
# template targets run driver 570/575.
RUN set -eu; \
    uv pip install torch==2.11.0 torchvision==0.26.0 torchaudio==2.11.0 \
      --index-url https://download.pytorch.org/whl/cu128; \
    uv pip install -r /comfyui/requirements.txt; \
    for r in /comfyui/custom_nodes/*/requirements.txt; do \
      [ -f "$r" ] && uv pip install -r "$r" || true; \
    done; \
    uv pip install "transformers>=4.50.3,<5" "huggingface-hub<1.0"

COPY verify_nodes.py /tmp/verify_nodes.py

# Fail the build here, not on a live worker, if the node graph cannot import or
# the Qwen 2.1 nodes are missing. This check is the entire point of the image.
RUN python /tmp/verify_nodes.py

WORKDIR /comfyui

# start.sh, handler.py and the runpod entrypoint are inherited from the base.
