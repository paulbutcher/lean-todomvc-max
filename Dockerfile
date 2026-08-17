# Build and runtime both start from the Lambda OS-only base so the binary is compiled against
# the same glibc it will run against. A binary built on the development image will not start
# here: that image is several glibc releases ahead of Amazon Linux 2023.

FROM public.ecr.aws/lambda/provided:al2023 AS build

# `dnf` here is a symlink to microdnf, which takes only a subset of dnf's options. curl is
# already present as curl-minimal, so elan's installer needs nothing added for it. leancurl
# compiles a shim against libcurl and finds it with pkg-config, so it needs both the headers and
# pkg-config itself, neither of which the minimal package carries.
RUN dnf install -y gcc git tar gzip libpq-devel openssl-devel libcurl-devel pkgconf-pkg-config \
    && dnf clean all

ENV ELAN_HOME=/opt/elan
ENV PATH=/opt/elan/bin:$PATH

WORKDIR /src

COPY lean-toolchain ./
RUN curl -fsSL https://elan.lean-lang.org/elan-init.sh \
      | sh -s -- -y --default-toolchain "$(cat lean-toolchain)"

# Dependencies are fetched and built before this project's own sources are copied in, so editing
# a handler doesn't rebuild the libraries underneath it.
COPY lakefile.toml lake-manifest.json ./
RUN lake build Postgres Html Htmx Routing Middleware MiddlewareCookieStore AwsLambdaHttp

# Everything else the context still holds after .dockerignore has had its say, so adding or
# renaming a source file needs no change here.
COPY . .
RUN lake build bootstrap && strip .lake/build/bin/bootstrap

# The collector that receives the function's telemetry, as a Lambda extension. It arrives as a
# layer archive, which is how it is published, but a layer is exactly what cannot be attached to a
# container-image function; unpacked into the image it registers through the Extensions API just
# the same. Pinned rather than tracked, since it is a 49MB binary on the cold-start path.
FROM public.ecr.aws/lambda/provided:al2023 AS collector

ARG COLLECTOR_VERSION=0.23.0

RUN dnf install -y unzip && dnf clean all
RUN curl -fsSL -o /tmp/collector.zip \
      "https://github.com/open-telemetry/opentelemetry-lambda/releases/download/layer-collector/${COLLECTOR_VERSION}/opentelemetry-collector-layer-arm64.zip" \
    && unzip -q /tmp/collector.zip -d /layer

FROM public.ecr.aws/lambda/provided:al2023

# `libpq` for leanpostgres, which brings the rest of its own chain (krb5, cyrus-sasl, zstd) with
# it. The cookie store's AES-GCM shim links `libcrypto` directly, but the base image already
# carries it: asking for `openssl-libs` by name fails, because what satisfies it here is
# `openssl-snapsafe-libs`, which conflicts with the package of that name.
#
# `libcurl` is what leancurl's shim links against, and the base image carries only the minimal
# build of it, which does not provide the full `libcurl.so.4`.
RUN dnf install -y libpq libcurl && dnf clean all

COPY --from=build /src/.lake/build/bin/bootstrap /var/task/bootstrap
# leancurl builds a shim as a shared library and the binary loads it by name at startup, so the
# binary alone is not a working function. `/usr/lib64` rather than alongside the binary, because
# it is searched without depending on what the runtime sets `LD_LIBRARY_PATH` to.
COPY --from=build /src/.lake/packages/leancurl/.lake/build/lib/libleancurl_shim.so /usr/lib64/
COPY --from=collector /layer/extensions/collector /opt/extensions/collector
COPY collector.yaml /var/task/collector.yaml
COPY public /var/task/public
COPY migrations /var/task/migrations

# The `file` middleware resolves "public" against the working directory, as does the migration
# runner "migrations".
WORKDIR /var/task

# The base image's entrypoint execs /var/task/bootstrap when it exists, and wraps it in the
# runtime interface emulator when AWS_LAMBDA_RUNTIME_API is unset, which is what makes this
# image runnable locally. It insists on exactly one argument, which an OS-only runtime never
# reads: the handler name is meaningful only to the managed runtimes.
CMD ["bootstrap"]
