FROM ubuntu:22.04

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive
ENV MXE_TARGET=x86_64-w64-mingw32.static
ENV MXE_DIR=/opt/mxe
ENV PATH=$MXE_DIR/usr/bin:$PATH

# 1. Install dependencies
RUN apt-get update && apt-get upgrade -y && \
    apt-get install -y \
      build-essential git python3-pip autoconf automake autopoint bash bison \
      bzip2 flex gettext gperf intltool libtool libtool-bin \
      libgdk-pixbuf2.0-dev libltdl-dev libssl-dev libxml-parser-perl \
      lzip make openssl p7zip-full patch perl pkg-config python3 ruby scons \
      sed unzip wget xz-utils g++-multilib libc6-dev-i386 zip cmake && \
    # Create a symlink from python3 to python (MXE requires 'python' command)
    ln -s /usr/bin/python3 /usr/bin/python && \
    pip3 install mako && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# 2. Clone and build MXE (with better caching)
WORKDIR /opt
RUN git clone https://github.com/mxe/mxe.git && \
    cd mxe && \
    echo "MXE_TARGETS := $MXE_TARGET" > settings.mk && \
    echo "MXE_PLUGIN_DIRS := plugins/gcc12" >> settings.mk

# 3. Build the MXE dependencies (this will take time)
WORKDIR /opt/mxe
# Build dependencies one by one to better identify any issues
RUN make -j$(nproc) MXE_TARGETS="$MXE_TARGET" cc && \
    make -j$(nproc) MXE_TARGETS="$MXE_TARGET" openssl && \
    make -j$(nproc) MXE_TARGETS="$MXE_TARGET" zlib && \
    make -j$(nproc) MXE_TARGETS="$MXE_TARGET" boost && \
    make -j$(nproc) MXE_TARGETS="$MXE_TARGET" libusb && \
    make -j$(nproc) MXE_TARGETS="$MXE_TARGET" hidapi && \
    make -j$(nproc) MXE_TARGETS="$MXE_TARGET" protobuf && \
    make -j$(nproc) MXE_TARGETS="$MXE_TARGET" libsodium && \
    make -j$(nproc) MXE_TARGETS="$MXE_TARGET" qt5 && \
    make -j$(nproc) MXE_TARGETS="$MXE_TARGET" qttools && \
    # Test that critical components were built successfully
    test -f usr/$MXE_TARGET/qt5/bin/qmake.exe

# 4. Clone nunchuk-desktop
WORKDIR /opt
RUN git clone https://github.com/nunchuk-io/nunchuk-desktop.git && \
    cd nunchuk-desktop && \
    git checkout 1.9.46 && \
    git submodule update --init --recursive

# 5. Create toolchain file
RUN echo '# MXE Cross-Compilation Toolchain File' > /opt/windows-toolchain.cmake && \
    echo 'set(CMAKE_SYSTEM_NAME Windows)' >> /opt/windows-toolchain.cmake && \
    echo 'set(CMAKE_SYSTEM_PROCESSOR x86_64)' >> /opt/windows-toolchain.cmake && \
    echo 'set(MXE_ROOT /opt/mxe)' >> /opt/windows-toolchain.cmake && \
    echo 'set(MXE_TARGET_PREFIX x86_64-w64-mingw32.static)' >> /opt/windows-toolchain.cmake && \
    echo 'set(CMAKE_C_COMPILER ${MXE_ROOT}/usr/bin/${MXE_TARGET_PREFIX}-gcc)' >> /opt/windows-toolchain.cmake && \
    echo 'set(CMAKE_CXX_COMPILER ${MXE_ROOT}/usr/bin/${MXE_TARGET_PREFIX}-g++)' >> /opt/windows-toolchain.cmake && \
    echo 'set(CMAKE_RC_COMPILER ${MXE_ROOT}/usr/bin/${MXE_TARGET_PREFIX}-windres)' >> /opt/windows-toolchain.cmake && \
    echo 'set(CMAKE_FIND_ROOT_PATH ${MXE_ROOT}/usr/${MXE_TARGET_PREFIX})' >> /opt/windows-toolchain.cmake && \
    echo 'set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)' >> /opt/windows-toolchain.cmake && \
    echo 'set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)' >> /opt/windows-toolchain.cmake && \
    echo 'set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)' >> /opt/windows-toolchain.cmake && \
    echo 'set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)' >> /opt/windows-toolchain.cmake && \
    echo 'set(QT_PREFIX ${MXE_ROOT}/usr/${MXE_TARGET_PREFIX}/qt5)' >> /opt/windows-toolchain.cmake && \
    echo 'set(CMAKE_PREFIX_PATH ${QT_PREFIX})' >> /opt/windows-toolchain.cmake && \
    echo 'set(PKG_CONFIG_EXECUTABLE ${MXE_ROOT}/usr/bin/${MXE_TARGET_PREFIX}-pkg-config)' >> /opt/windows-toolchain.cmake

# 6. Build nunchuk-desktop
WORKDIR /opt
RUN mkdir -p nunchuk-build && cd nunchuk-build && \
    cmake ../nunchuk-desktop \
      -DCMAKE_TOOLCHAIN_FILE=/opt/windows-toolchain.cmake \
      -DCMAKE_BUILD_TYPE=Release \
      -DQT_HOST_PATH=/opt/mxe/usr/$MXE_TARGET/qt5 && \
    make -j$(nproc) && \
    # Verify build completed successfully
    test -f nunchuk.exe

# 7. Package properly with Qt dependencies for Windows
WORKDIR /opt
RUN mkdir -p nunchuk-windows && \
    # Copy the executable
    cp nunchuk-build/nunchuk.exe nunchuk-windows/ && \
    # For static builds, additional DLLs are typically not needed as they're compiled into the executable
    # However, if there are runtime dependencies (like OpenSSL), we should include them:
    # Copy any required DLLs for static build (if needed)
    cp -r /opt/mxe/usr/$MXE_TARGET/bin/*.dll nunchuk-windows/ 2>/dev/null || true && \
    # Copy other necessary resources
    cp -r /opt/nunchuk-desktop/resources nunchuk-windows/ 2>/dev/null || true && \
    # Package everything
    cd nunchuk-windows && \
    zip -r ../nunchuk-windows.zip ./* && \
    # Verify package was created
    cd .. && test -f nunchuk-windows.zip

# Create a final stage to reduce image size
FROM ubuntu:22.04
COPY --from=0 /opt/nunchuk-windows.zip /nunchuk-windows.zip
WORKDIR /
CMD ["echo", "Build completed. The Windows package is available at /nunchuk-windows.zip"]
