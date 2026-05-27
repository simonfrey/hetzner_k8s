FROM node:22-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      git \
      ca-certificates \
      curl \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

# Create non-root user
RUN groupadd -g 10001 claude \
    && useradd -u 10001 -g 10001 -m -d /home/claude -s /bin/bash claude \
    && mkdir -p /workspaces \
    && chown -R 10001:10001 /home/claude /workspaces

USER 10001

CMD ["sleep", "infinity"]
