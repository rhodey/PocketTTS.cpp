ARG PYTHON_IMAGE=python:3.12-slim-bookworm
ARG POCKET_TTS_REF=058886528d0b6f2f2d4022de2e244a5260729e6e
ARG EXPORTER_ONNXRUNTIME_VERSION=1.23.2
ARG ONNXRUNTIME_VERSION=1.23.2

FROM ${PYTHON_IMAGE} AS exporter
ARG POCKET_TTS_REF
ARG EXPORTER_ONNXRUNTIME_VERSION

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /src

RUN apt-get update && \
    apt-get install -y --no-install-recommends git ca-certificates && \
    rm -rf /var/lib/apt/lists/*

COPY export_onnx.py ./

RUN python -m pip install --upgrade pip && \
    python -m pip install --index-url https://download.pytorch.org/whl/cpu torch && \
    python -m pip install \
        "pocket-tts @ git+https://github.com/kyutai-labs/pocket-tts.git@${POCKET_TTS_REF}" \
        onnx \
        "onnxruntime==${EXPORTER_ONNXRUNTIME_VERSION}" && \
    python -m pip freeze | tee /opt/pocket-tts-exporter-requirements.txt

RUN mkdir -p /opt/pocket-tts/models && \
    python export_onnx.py --output-dir /opt/pocket-tts/models --language english_2026-01 --no-validate


FROM ${PYTHON_IMAGE} AS builder
ARG ONNXRUNTIME_VERSION

ENV PIP_NO_CACHE_DIR=1

WORKDIR /src

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        git && \
    rm -rf /var/lib/apt/lists/*

RUN python -m pip install --upgrade pip cmake

COPY CMakeLists.txt pocket_tts.cpp ./

RUN cmake -S . -B /tmp/build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIB=OFF -DONNXRUNTIME_VERSION="${ONNXRUNTIME_VERSION}" && \
    cmake --build /tmp/build -j"$(nproc)"

RUN mkdir -p /opt/pocket-tts/runtime && \
    install -Dm755 /src/pocket-tts /opt/pocket-tts/runtime/pocket-tts && \
    cp -a /tmp/build/_deps/onnxruntime-src/lib/. /opt/pocket-tts/runtime/


FROM ${PYTHON_IMAGE} AS runtime

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        libgomp1 && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

ENV LD_LIBRARY_PATH=/app

COPY --from=builder /opt/pocket-tts/runtime/ /app/
COPY --from=exporter /opt/pocket-tts/models/ /app/models/
COPY --from=exporter /opt/pocket-tts-exporter-requirements.txt /app/exporter-requirements.txt

RUN mkdir -p /app/voices/.cache

EXPOSE 8080

ENTRYPOINT ["/app/pocket-tts"]
CMD ["--server", "--port", "8080"]
