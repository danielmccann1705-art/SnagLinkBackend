# Local acceptance candidate only. Caller verifies the exact supplied base image
# ID; no production runtime or frozen backend image is changed by this build.
ARG PROCESSOR_BASE_IMAGE=snaglist-drawing-dra02:corrected
FROM ${PROCESSOR_BASE_IMAGE} AS core-build
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
    g++=4:11.2.0-1ubuntu1 pkg-config=0.29.2-1ubuntu3 dpkg-dev=1.21.1ubuntu2.6 \
    cmake=3.22.1-1ubuntu1.22.04.2 ninja-build=1.10.1-1 \
    libfreetype-dev=2.11.1+dfsg-1ubuntu0.3 libfontconfig1-dev=2.13.1-4.2ubuntu5 \
    liblcms2-dev=2.12~rc1-2ubuntu0.1 zlib1g-dev=1:1.2.11.dfsg-2ubuntu9.2 \
    libpng-dev=1.6.37-3ubuntu0.6 libopenjp2-7-dev=2.4.0-6ubuntu0.5 \
    libjpeg-turbo8-dev=2.1.2-0ubuntu1 && rm -rf /var/lib/apt/lists/*
COPY upstream/poppler_*.tar.xz upstream/poppler_*.dsc /build/source/
COPY nojbig2/source-tree.json nojbig2/patch_poppler.py nojbig2/verify_archives.py /build/policy/
RUN /usr/bin/python3 /build/policy/verify_archives.py /build/source && \
    cd /build/source && dpkg-source -x poppler_22.02.0-2ubuntu0.13.dsc /build/poppler
RUN /usr/bin/python3 /build/policy/patch_poppler.py /build/poppler /build/policy/source-tree.json /build/decoder-policy.json
RUN cmake -S /build/poppler -B /build/core -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/opt/snaglist-poppler -DCMAKE_INSTALL_LIBDIR=lib \
    -DENABLE_UNSTABLE_API_ABI_HEADERS=ON -DENABLE_UTILS=OFF -DENABLE_CPP=OFF \
    -DENABLE_GLIB=OFF -DENABLE_GOBJECT_INTROSPECTION=OFF -DENABLE_GTK_DOC=OFF \
    -DENABLE_QT5=OFF -DENABLE_QT6=OFF -DENABLE_BOOST=OFF -DENABLE_LIBCURL=OFF \
    -DENABLE_CMS=lcms2 -DENABLE_LIBOPENJPEG=openjpeg2 -DENABLE_DCTDECODER=libjpeg \
    -DCMAKE_DISABLE_FIND_PACKAGE_Cairo=ON -DBUILD_GTK_TESTS=OFF -DBUILD_QT5_TESTS=OFF \
    -DBUILD_QT6_TESTS=OFF -DBUILD_CPP_TESTS=OFF -DBUILD_MANUAL_TESTS=OFF \
    -DCMAKE_CXX_FLAGS_RELEASE='-O2 -DNDEBUG -ffile-prefix-map=/build=.'
RUN cmake --build /build/core -j 2 && cmake --install /build/core
# This assertion detects accidental retention/reintroduction of the decoder.
RUN nm -C /opt/snaglist-poppler/lib/libpoppler.so.118.0.0 > /build/core-symbols.txt && \
    ! grep -F 'JBIG2Stream::' /build/core-symbols.txt
COPY nojbig2/processor/drawing_pdf.cpp /build/drawing_pdf.cpp
RUN g++ -std=c++17 -O2 -Wall -Wextra -Werror -Wno-unused-function -ffile-prefix-map=/build=. \
    -isystem /opt/snaglist-poppler/include -isystem /opt/snaglist-poppler/include/poppler /build/drawing_pdf.cpp \
    -L/opt/snaglist-poppler/lib -Wl,-rpath,/opt/snaglist-poppler/lib -lpoppler -ljpeg -o /drawing-pdf

FROM ${PROCESSOR_BASE_IMAGE} AS candidate
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
    libfreetype6=2.11.1+dfsg-1ubuntu0.3 libfontconfig1=2.13.1-4.2ubuntu5 \
    liblcms2-2=2.12~rc1-2ubuntu0.1 zlib1g=1:1.2.11.dfsg-2ubuntu9.2 \
    libopenjp2-7=2.4.0-6ubuntu0.5 && rm -rf /var/lib/apt/lists/*
COPY --from=core-build /opt/snaglist-poppler /opt/snaglist-poppler
COPY --from=core-build /build/decoder-policy.json /opt/snaglist-drawing/decoder-policy.json
COPY --from=core-build /build/core-symbols.txt /opt/snaglist-drawing/core-symbols.txt
COPY --from=core-build /drawing-pdf /opt/snaglist-drawing/drawing-pdf
COPY processor/*.py /opt/snaglist-drawing/
COPY runtime/profile.py /opt/snaglist-drawing/profile-build.py
COPY nojbig2/profile_extension.py /opt/snaglist-drawing/profile-extension.py
RUN /usr/bin/python3 /opt/snaglist-drawing/profile-build.py /opt/snaglist-drawing && \
    /usr/bin/python3 /opt/snaglist-drawing/profile-extension.py /opt/snaglist-drawing
COPY tests /opt/snaglist-drawing-tests
COPY nojbig2/tests /opt/snaglist-drawing-tests
USER vapor
WORKDIR /tmp
ENTRYPOINT ["/usr/bin/python3"]
CMD ["-m", "unittest", "discover", "-v", "-s", "/opt/snaglist-drawing-tests"]
