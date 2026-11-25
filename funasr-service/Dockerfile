ARG PYTHON_IMAGE=python:3.11-slim
FROM ${PYTHON_IMAGE}
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1 \
    MODELSCOPE_CACHE=/models/modelscope HF_HOME=/models/huggingface
WORKDIR /app
ARG DEBIAN_MIRROR=http://deb.debian.org
RUN sed -i "s|http://deb.debian.org|${DEBIAN_MIRROR}|g" /etc/apt/sources.list.d/debian.sources \
 && apt-get update && apt-get install -y --no-install-recommends ffmpeg libsndfile1 \
 && rm -rf /var/lib/apt/lists/*
COPY requirements.txt ./
RUN pip install --index-url https://download.pytorch.org/whl/cpu torch==2.8.0 torchaudio==2.8.0
RUN pip install -r requirements.txt
COPY server.py speaker_diarization.py ./
EXPOSE 10095
CMD ["python", "-m", "uvicorn", "server:app", "--host", "0.0.0.0", "--port", "10095"]
