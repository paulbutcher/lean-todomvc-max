FROM mcr.microsoft.com/devcontainers/base:resolute
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      libpq-dev \
      postgresql-client \
      unzip \
    && rm -rf /var/lib/apt/lists/*

RUN case "$(uname -m)" in \
      x86_64) sam_arch=x86_64 ;; \
      aarch64) sam_arch=arm64 ;; \
      *) echo "no AWS SAM CLI build for $(uname -m)" >&2; exit 1 ;; \
    esac \
    && curl -fsSL -o /tmp/aws-sam-cli.zip \
      "https://github.com/aws/aws-sam-cli/releases/latest/download/aws-sam-cli-linux-${sam_arch}.zip" \
    && unzip -q /tmp/aws-sam-cli.zip -d /tmp/sam-installation \
    && /tmp/sam-installation/install \
    && rm -rf /tmp/aws-sam-cli.zip /tmp/sam-installation \
    && sam --version

USER vscode
ENV PATH="/home/vscode/.local/bin:/home/vscode/.elan/bin:${PATH}"
RUN curl https://elan.lean-lang.org/elan-init.sh -sSf | sh -s -- -y
RUN elan toolchain install stable
RUN curl -fsSL https://claude.ai/install.sh | bash
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
