# LOCAL/hosted capability probe only. This image cannot process drawing bytes.
# Pin PROCESSOR_IMAGE to the reviewed no-JBIG2 candidate digest before building.
ARG PROCESSOR_IMAGE
FROM ${PROCESSOR_IMAGE} AS probe-build
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc=4:11.2.0-1ubuntu1 libc6-dev && \
    rm -rf /var/lib/apt/lists/*
COPY Tools/DrawingProcessor/hosted/sandbox_launcher.c /build/sandbox_launcher.c
RUN gcc -std=c17 -O2 -Wall -Wextra -Werror -Wformat=2 \
    -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fPIE -pie \
    -Wl,-z,relro,-z,now /build/sandbox_launcher.c -o /build/sandbox-launcher

FROM ${PROCESSOR_IMAGE} AS hosted-probe
USER root
COPY --from=probe-build /build/sandbox-launcher /opt/snaglist-drawing-hosted/sandbox-launcher
COPY Tools/DrawingProcessor/hosted/protocol.py Tools/DrawingProcessor/hosted/supervisor.py /opt/snaglist-drawing-hosted/
RUN mkdir -p /run/snaglist-hosted-probe && \
    chown 65532:65532 /run/snaglist-hosted-probe && chmod 0700 /run/snaglist-hosted-probe && \
    test -f /opt/snaglist-drawing/runtime-profile.json && \
    test -x /opt/snaglist-drawing-hosted/sandbox-launcher
WORKDIR /opt/snaglist-drawing-hosted
ENTRYPOINT ["/usr/bin/python3", "/opt/snaglist-drawing-hosted/supervisor.py", "--probe"]
