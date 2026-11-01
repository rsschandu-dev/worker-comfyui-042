# syntax=docker/dockerfile:1
# RunPod ComfyUI worker pinned to ComfyUI 0.42.0 (Qwen Image 2.1 era), built
# lean.
#
# Why not FROM runpod/worker-comfyui:5.10.0-base? That base already carries a
# complete ComfyUI 0.34 workspace + its own torch in /comfyui/.venv. A
# `rm -rf /comfyui` only whiteouts those lower layers — it does not shrink the
# image — and reinstalling torch re-adds a byte-identical copy. The result was a
# ~19GB image whose cold pull dominated worker boot time.
#
# This build instead starts from the CUDA base directly, installs ComfyUI 0.42
# once (no 0.34, no duplicate torch), and imports the RunPod worker runtime
# scripts verbatim from the published base image. The Qwen 2.1 nodes
# (QwenImage21Cache, TextEncodeQwenImage21) are what the 0.34 image lacks.

# Stage 1: the published base is used only as a source for the worker runtime
# scripts (start.sh, handler.py, network_volume.py, the extra_model_paths and
# the comfy-manager helpers) so they stay byte-identical to a working release.
FROM runpod/worker-comfyui:5.10.0-base AS worker-scripts

# Stage 2: the actual runtime image.
FROM nvidia/cuda:12.8.1-cudnn-runtime-ubuntu24.04

ARG COMFYUI_VERSION=0.42.0
ARG CUDA_VERSION_FOR_COMFY=12.8

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_PREFER_BINARY=1 \
    PIP_NO_INPUT=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:/usr/local/bin:/usr/bin:/bin"

# Same OS dependency set the worker base installs.
RUN apt-get update && apt-get install -y \
    python3.12 python3.12-venv git wget \
    libgl1 libglib2.0-0 libsm6 libxext6 libxrender1 \
    ffmpeg openssh-server \
    && ln -sf /usr/bin/python3.12 /usr/bin/python \
    && ln -sf /usr/bin/pip3 /usr/bin/pip \
    && apt-get clean -y && rm -rf /var/lib/apt/lists/*

# uv + an isolated launch venv (start.sh runs ComfyUI and handler.py with it).
RUN wget -qO- https://astral.sh/uv/install.sh | sh \
    && ln -s /root/.local/bin/uv /usr/local/bin/uv \
    && ln -s /root/.local/bin/uvx /usr/local/bin/uvx \
    && uv venv /opt/venv

# comfy-cli, pinned: its install / torch-index behavior decides what lands in
# the workspace venv, so an unpinned version makes builds non-reproducible.
RUN uv pip install comfy-cli==1.13.0 pip setuptools wheel

# Install ComfyUI 0.42, then drop the workspace venv. comfy-cli installs a
# private torch into /comfyui/.venv that start.sh never uses (it launches with
# /opt/venv), so deleting it removes a multi-GB duplicate torch instead of
# shipping it.
RUN /usr/bin/yes | comfy --workspace /comfyui install \
      --version "${COMFYUI_VERSION}" \
      --cuda-version "${CUDA_VERSION_FOR_COMFY}" \
      --nvidia \
    && rm -rf /comfyui/.venv

# Mirror ComfyUI 0.42's runtime deps into /opt/venv.
#
# torch is installed FIRST, pinned to +cu128 builds: ComfyUI's requirements.txt
# declares a bare `torch`, and default PyPI serves CUDA 13 builds (torch's PyPI
# wheels depend on nvidia-*-cu13 since 2.11) that require driver >= 580. Hosts
# advertise CUDA 12.8/12.9/13.2 (driver 570+, 580); a cu128 build runs on every
# one of them, while cu13 would fail CUDA init on the 570/575 hosts. Installing
# torch first satisfies the bare `torch` requirement so the PyPI pass leaves it
# alone.
#
# transformers / huggingface-hub are pinned in the SAME step so their breaking
# 5.x / 1.x versions are downgraded within one layer rather than left behind.
RUN uv pip install torch==2.11.0 torchvision==0.26.0 torchaudio==2.11.0 \
      --index-url https://download.pytorch.org/whl/cu128 \
    && uv pip install -r /comfyui/requirements.txt \
    && for r in /comfyui/custom_nodes/*/requirements.txt; do \
         [ -f "$r" ] && uv pip install -r "$r" || true; \
       done \
    && uv pip install "transformers>=4.50.3,<5" "huggingface-hub<1.0" \
    && uv pip install runpod requests websocket-client

# Import the RunPod worker runtime verbatim from the published base image.
COPY --from=worker-scripts /start.sh /start.sh
COPY --from=worker-scripts /handler.py /handler.py
COPY --from=worker-scripts /network_volume.py /network_volume.py
COPY --from=worker-scripts /comfyui/extra_model_paths.yaml /comfyui/extra_model_paths.yaml
COPY --from=worker-scripts /usr/local/bin/comfy-node-install /usr/local/bin/comfy-node-install
COPY --from=worker-scripts /usr/local/bin/comfy-manager-set-mode /usr/local/bin/comfy-manager-set-mode
RUN chmod +x /start.sh /usr/local/bin/comfy-node-install /usr/local/bin/comfy-manager-set-mode

COPY verify_nodes.py /tmp/verify_nodes.py

WORKDIR /comfyui

# Fail the build — not a live worker — if ComfyUI 0.42 cannot import or the
# Qwen 2.1 nodes are missing.
RUN python /tmp/verify_nodes.py

WORKDIR /
CMD ["/start.sh"]