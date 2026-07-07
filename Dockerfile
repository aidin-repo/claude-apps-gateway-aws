# Claude apps gateway image: native claude binary on a glibc base.
# The gateway server requires the native binary (it won't run under Node).
# Pulls gateway.yaml from S3 at startup (GATEWAY_CONFIG_S3_URI). NO baked
# fallback — shipping a stale/personal config silently is worse than crashing
# with a clear error. See entrypoint.sh.
# Base pulled from the ECR Public mirror of Docker Hub to avoid Docker Hub rate limits.
FROM public.ecr.aws/docker/library/debian:bookworm-slim

# Pin every network-fetched dependency. Every developer machine's `claude`
# must be on CLAUDE_VERSION or later for gateway support (>= 2.1.195).
ARG CLAUDE_VERSION=2.1.201
ARG AWSCLI_VERSION=2.17.0

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl unzip \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --shell /usr/sbin/nologin --uid 10001 gateway

# AWS CLI v2 (pinned), used by the entrypoint to fetch the config from S3 (task-role creds).
# Installed to /usr/local/bin so both root (install phase) and the gateway user (runtime) can invoke it.
RUN curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-${AWSCLI_VERSION}.zip" -o /tmp/awscliv2.zip \
    && unzip -q /tmp/awscliv2.zip -d /tmp && /tmp/aws/install \
    && rm -rf /tmp/aws /tmp/awscliv2.zip

# /etc/claude is writable by the gateway user so entrypoint.sh can write the fetched config.
RUN mkdir -p /etc/claude && chown gateway:gateway /etc/claude

# Install the pinned native build as the non-root gateway user so its ~/.local/bin lives under /home/gateway.
USER gateway
WORKDIR /home/gateway
RUN curl -fsSL https://claude.ai/install.sh | bash -s "${CLAUDE_VERSION}"

ENV PATH="/home/gateway/.local/bin:${PATH}"
ENV CLAUDE_CONFIG_DIR=/tmp/.claude

COPY --chown=gateway:gateway entrypoint.sh /usr/local/bin/entrypoint.sh
USER root
RUN chmod +x /usr/local/bin/entrypoint.sh
USER gateway

EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
