ARG UBUNTU_IMAGE=ubuntu:24.04
FROM ${UBUNTU_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    iproute2 \
    python3 \
  && rm -rf /var/lib/apt/lists/*

COPY backend-server.py /usr/local/bin/backend-server.py
RUN chmod +x /usr/local/bin/backend-server.py

EXPOSE 8080
CMD ["/usr/bin/python3", "/usr/local/bin/backend-server.py"]
