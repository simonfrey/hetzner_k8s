FROM node:22-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      git \
      ca-certificates \
      curl \
      tmux \
      procps \
      locales \
    && sed -i '/en_US.UTF-8/s/^# //' /etc/locale.gen \
    && locale-gen \
    && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

RUN npm install -g @anthropic-ai/claude-code

# Create non-root user
RUN groupadd -g 10001 claude \
    && useradd -u 10001 -g 10001 -m -d /home/claude -s /bin/bash claude \
    && mkdir -p /workspaces \
    && chown -R 10001:10001 /home/claude /workspaces

# tmux config: large scrollback, no escape delay, 256-color
COPY tmux.conf /etc/tmux.conf

USER 10001

CMD ["sleep", "infinity"]
