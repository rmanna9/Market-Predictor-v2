# Stage 1: Build 
FROM python:3.11-slim AS builder

WORKDIR /app

# Crea il venv PRIMA, poi aggiorna pip/wheel DENTRO di esso
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Fix CVE-2026-24049 (wheel) e CVE-2026-1703 / CVE-2025-8869 (pip)
RUN pip install --no-cache-dir --upgrade "pip>=26.0" "wheel>=0.46.2" setuptools

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt


# Stage 2: Runtime
FROM python:3.11-slim AS runtime

# Fix pip/wheel bundled nell'immagine base (indipendenti dal venv del builder)
RUN pip install --no-cache-dir --upgrade "pip>=26.0" "wheel>=0.46.2" setuptools

RUN useradd --create-home --shell /bin/bash appuser

# Il venv include già pip>=26.0 e wheel>=0.46.2 aggiornati
COPY --from=builder /opt/venv /opt/venv

ENV PATH="/opt/venv/bin:$PATH"
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

WORKDIR /home/appuser/app
COPY --chown=appuser:appuser app.py .

USER appuser

EXPOSE 8501
ENTRYPOINT ["streamlit", "run", "app.py", \
    "--server.port=8501", \
    "--server.address=0.0.0.0", \
    "--server.headless=true", \
    "--server.runOnSave=false"]