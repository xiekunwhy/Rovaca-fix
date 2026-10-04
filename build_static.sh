#!/bin/bash
# Fully static build of rovaca for x86-64 Linux (no root required).
#
# Produces a single self-contained binary at build/bin/rovaca that runs on any
# x86-64 Linux with kernel >= 3.2 and a CPU with AVX2 (AVX-512 preferred),
# regardless of the host glibc version.
#
# Dependencies are fetched/built into third_lib/static-deps (not committed).
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
DEPS="$ROOT/third_lib/static-deps"
JOBS="$(nproc)"
mkdir -p "$DEPS/lib" "$DEPS/include" "$DEPS/src"

# ---- 1. zlib / bzip2 / xz / boost.program_options static libs + headers ----
if [ ! -f "$DEPS/lib/libz.a" ] || [ ! -f "$DEPS/lib/libboost_program_options.a" ]; then
    if command -v apt-get >/dev/null 2>&1; then
        echo ">> fetching static deps via apt download (no root needed)"
        cd "$DEPS/src"
        apt-get download zlib1g-dev libbz2-dev liblzma-dev \
            libboost-program-options1.83-dev libboost1.83-dev
        mkdir -p "$DEPS/tmp"
        for f in *.deb; do dpkg -x "$f" "$DEPS/tmp"; done
        cp "$DEPS"/tmp/usr/lib/x86_64-linux-gnu/libz.a \
           "$DEPS"/tmp/usr/lib/x86_64-linux-gnu/libbz2.a \
           "$DEPS"/tmp/usr/lib/x86_64-linux-gnu/liblzma.a \
           "$DEPS"/tmp/usr/lib/x86_64-linux-gnu/libboost_program_options.a \
           "$DEPS/lib/"
        cp -r "$DEPS"/tmp/usr/include/. "$DEPS/include/"
        rm -rf "$DEPS/tmp" ./*.deb
    else
        echo "Non-Debian system: please place libz.a libbz2.a liblzma.a" \
             "libboost_program_options.a into $DEPS/lib and the matching" \
             "headers (incl. boost/) into $DEPS/include, then re-run." >&2
        exit 1
    fi
fi

# ---- 2. htslib 1.18 static (bz2+lzma enabled for full CRAM codec support) ----
if [ ! -f "$DEPS/lib/libhts.a" ]; then
    echo ">> building htslib 1.18 (static)"
    cd "$DEPS/src"
    if [ ! -d htslib-1.18 ]; then
        wget -q https://github.com/samtools/htslib/releases/download/1.18/htslib-1.18.tar.bz2
        tar xf htslib-1.18.tar.bz2
    fi
    cd htslib-1.18
    ./configure --disable-libcurl --disable-gcs --disable-s3 --disable-plugins \
        CPPFLAGS="-I$DEPS/include" LDFLAGS="-L$DEPS/lib"
    make -j"$JOBS" libhts.a
    cp libhts.a "$DEPS/lib/"
fi

# ---- 3. configure + build rovaca (static) ----
echo ">> building rovaca (static)"
cd "$ROOT"
mkdir -p build
cd build
cmake -DROVACA_STATIC=ON -DCMAKE_INSTALL_PREFIX=../release ..
make -j"$JOBS"

echo
echo "Static binary: $ROOT/build/bin/rovaca"
file "$ROOT/build/bin/rovaca" || true
