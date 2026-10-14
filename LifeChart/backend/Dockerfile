FROM python:3.13-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /srv
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app

RUN useradd --create-home --uid 1000 lifechart && mkdir -m 700 /data && chown lifechart /data
USER lifechart
VOLUME /data
EXPOSE 8080

HEALTHCHECK --interval=60s --timeout=5s \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/health')"

CMD ["uvicorn", "--factory", "app.main:build_app", "--host", "0.0.0.0", "--port", "8080", "--proxy-headers"]
