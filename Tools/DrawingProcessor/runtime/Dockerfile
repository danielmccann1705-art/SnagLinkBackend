# Isolated prototype worker only. Does not modify the backend's Dockerfile/image.
# The caller verifies BASE_IMAGE against the recorded local immutable image ID.
ARG BASE_IMAGE=snaglist-unified-staging:91a53d9
FROM ${BASE_IMAGE} AS build
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
    g++=4:11.2.0-1ubuntu1 pkg-config=0.29.2-1ubuntu3 \
    libpoppler-dev=22.02.0-2ubuntu0.13 libpoppler-private-dev=22.02.0-2ubuntu0.13 \
    libjpeg-turbo8-dev=2.1.2-0ubuntu1 && rm -rf /var/lib/apt/lists/*
COPY processor/drawing_pdf.cpp /build/drawing_pdf.cpp
RUN g++ -std=c++17 -O2 -Wall -Wextra -Werror -Wno-unused-function \
    -ffile-prefix-map=/build=. /build/drawing_pdf.cpp \
    -isystem /usr/include/poppler $(pkg-config --libs poppler) -ljpeg -o /drawing-pdf

FROM ${BASE_IMAGE} AS runtime
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpoppler118=22.02.0-2ubuntu0.13 python3-pil=9.0.1-1ubuntu0.5 \
    libjpeg-turbo8=2.1.2-0ubuntu1 libpng16-16=1.6.37-3ubuntu0.6 \
    fonts-dejavu-core=2.37-2build1 poppler-data=0.4.11-1 && rm -rf /var/lib/apt/lists/*
COPY --from=build /drawing-pdf /opt/snaglist-drawing/drawing-pdf
COPY processor/*.py /opt/snaglist-drawing/
COPY runtime/profile.py /opt/snaglist-drawing/profile-build.py
RUN /usr/bin/python3 /opt/snaglist-drawing/profile-build.py /opt/snaglist-drawing
COPY tests /opt/snaglist-drawing-tests
USER vapor
WORKDIR /tmp
ENTRYPOINT ["/usr/bin/python3"]
CMD ["-m", "unittest", "discover", "-v", "-s", "/opt/snaglist-drawing-tests"]
