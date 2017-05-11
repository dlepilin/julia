#!/bin/sh
# This file is a part of Julia. License is MIT: https://julialang.org/license

# Run as: fixup-freebsd-libs.sh <patchelf> <julia_libdir> <gcc_dir>

if [ ! "$(uname -s)" = "FreeBSD" ]; then
    echo "This script is only intended to be run from FreeBSD"
    exit 1
fi

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <patchelf> <julia_libdir> <gcc_dir>"
    exit 1
fi

patchelf="$1"
libdir="$2"
gccdir="$3"

cd "$libdir"

# These are the system libraries which link to libgcc_s. If we don't patch them to use our
# libgcc_s, LLVM will link to them and there will be conflicting GCC versions. So we'll fix
# them by copying them into our lib directory and setting the RPATHs.
for badlib in /usr/lib/libc++.so.1 /lib/libcxxrt.so.1; do
    cp -v "$badlib" "$libdir"
    new="$(basename $badlib)"
    chmod 755 $new
    $patchelf --set-rpath \$ORIGIN:$gccdir $new
done
