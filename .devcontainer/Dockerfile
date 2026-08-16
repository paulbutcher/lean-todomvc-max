FROM mcr.microsoft.com/devcontainers/base:resolute
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      libpq-dev \
      postgresql-client \
    && rm -rf /var/lib/apt/lists/*

USER vscode
ENV PATH="/home/vscode/.local/bin:/home/vscode/.elan/bin:${PATH}"
RUN curl https://elan.lean-lang.org/elan-init.sh -sSf | sh -s -- -y
RUN elan toolchain install stable
RUN curl -fsSL https://claude.ai/install.sh | bash
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
