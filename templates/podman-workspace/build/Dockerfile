FROM python:3.14-slim AS python314

FROM debian:trixie

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    podman \
    fuse-overlayfs \
    slirp4netns \
    uidmap \
    git \
    curl \
    wget \
    jq \
    unzip \
    build-essential \
    openssh-client \
    sudo \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=python314 /usr/local /usr/local

RUN ln -sf /usr/local/bin/python3.14 /usr/bin/python3 && \
    ln -sf /usr/local/bin/python3.14 /usr/bin/python && \
    ln -sf /usr/local/bin/pip3 /usr/bin/pip3 && \
    ln -sf /usr/local/bin/pip3 /usr/bin/pip

COPY storage.conf /etc/containers/storage.conf

RUN echo '[registries.search]' > /etc/containers/registries.conf && \
    echo 'registries = ["docker.io", "quay.io", "ghcr.io"]' >> /etc/containers/registries.conf

ARG USER_UID=1000
RUN useradd -m -s /bin/bash -u ${USER_UID} coder && \
    echo "coder ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/coder && \
    chmod 0440 /etc/sudoers.d/coder

COPY containers.conf /etc/containers/containers.conf
RUN mkdir -p /home/coder/.config/containers && \
    cp /etc/containers/storage.conf /home/coder/.config/containers/storage.conf && \
    cp /etc/containers/containers.conf /home/coder/.config/containers/containers.conf && \
    chown -R coder:coder /home/coder

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
