# Build and runtime both start from the Lambda OS-only base so the binary is compiled against
# the same glibc it will run against. A binary built on the development image will not start
# here: that image is several glibc releases ahead of Amazon Linux 2023.

FROM public.ecr.aws/lambda/provided:al2023 AS build

# `dnf` here is a symlink to microdnf, which takes only a subset of dnf's options. curl is
# already present as curl-minimal, so elan's installer needs nothing added for it.
RUN dnf install -y gcc git tar gzip libpq-devel openssl-devel pkgconf-pkg-config && dnf clean all

# leancurl compiles a shim against libcurl and locates it with pkg-config, so it needs the headers
# and the `.pc` file that only the development package carries. That package conflicts with the
# `libcurl-minimal` the base image ships, and this `dnf` has no `--allowerasing`, so the exchange
# has to be asked for directly. Only the build stage needs it: `libcurl-minimal` already provides
# the `libcurl.so.4` the shim loads at runtime.
RUN dnf swap -y libcurl-minimal libcurl-devel && dnf clean all

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

FROM public.ecr.aws/lambda/provided:al2023

# `libpq` for leanpostgres, which brings the rest of its own chain (krb5, cyrus-sasl, zstd) with
# it. The cookie store's AES-GCM shim links `libcrypto` directly, but the base image already
# carries it: asking for `openssl-libs` by name fails, because what satisfies it here is
# `openssl-snapsafe-libs`, which conflicts with the package of that name.
#
# Nothing is added for leancurl: its shim needs `libcurl.so.4` at load time, and the
# `libcurl-minimal` already in the base image provides exactly that soname.
RUN dnf install -y libpq && dnf clean all

COPY --from=build /src/.lake/build/bin/bootstrap /var/task/bootstrap
# leancurl builds a shim as a shared library and the binary loads it by name at startup, so the
# binary alone is not a working function. `/usr/lib64` rather than alongside the binary, because
# it is searched without depending on what the runtime sets `LD_LIBRARY_PATH` to.
COPY --from=build /src/.lake/packages/leancurl/.lake/build/lib/libleancurl_shim.so /usr/lib64/
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
