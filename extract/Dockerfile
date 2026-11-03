# BeeGs extract job - runs on GitHub Actions (scheduled), image in GitHub Container Registry; one image, several tasks (BEEGS_TASK)
# Pinned base image: rebuilds are reproducible.
FROM python:3.12.7-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

# 1) dependencies first -> this layer is cached as long as requirements.txt does not change
COPY extract/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

# 2) then the code (changes often)
COPY config/ /app/config/
COPY data_generator/ /app/data_generator/
COPY extract/beegs_extract/ /app/beegs_extract/

# Never run as root
RUN useradd --create-home --uid 10001 beegs
USER beegs

# No secret in the image: the Snowflake private key is injected at run time (docker run -e, from a GitHub secret)
# and never written to disk.
ENTRYPOINT ["python", "-m", "beegs_extract.main"]
