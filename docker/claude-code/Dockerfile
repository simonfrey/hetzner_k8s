FROM node:22-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      openssh-server \
      git \
      ca-certificates \
      curl \
      iproute2 \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

# Create non-root user
RUN groupadd -g 10001 claude \
    && useradd -u 10001 -g 10001 -m -d /home/claude -s /bin/bash claude \
    && mkdir -p /home/claude/.ssh-host-keys /workspaces /run/sshd \
    && chown -R 10001:10001 /home/claude /workspaces

COPY sshd_config /etc/ssh/sshd_config
COPY --chmod=755 entrypoint.sh /entrypoint.sh

USER 10001
EXPOSE 2222

CMD ["/entrypoint.sh"]
