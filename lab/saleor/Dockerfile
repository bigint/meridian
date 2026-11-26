# Saleor's published images, labelled for Kamal (which only boots images that
# carry their service label). The API image also gets lab-saleor, below.
ARG IMAGE
FROM ${IMAGE} AS dashboard
ARG SERVICE
LABEL service=$SERVICE

FROM ${IMAGE} AS api
ARG SERVICE
LABEL service=$SERVICE
COPY --chmod=755 entrypoint.sh /usr/local/bin/lab-saleor
COPY migrate.py /usr/local/bin/lab-saleor-migrate
ENTRYPOINT ["/usr/local/bin/lab-saleor"]
# Setting ENTRYPOINT clears the inherited CMD, so restate Saleor's own.
CMD ["uvicorn", "saleor.asgi:application", "--host=0.0.0.0", "--port=8000", "--workers=2", "--lifespan=off", "--ws=none", "--no-server-header", "--no-access-log", "--timeout-keep-alive=35", "--timeout-graceful-shutdown=30", "--limit-max-requests=10000"]
