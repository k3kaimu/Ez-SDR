FROM ghcr.io/k3kaimu/uhd:v4.7

WORKDIR /work

# install bladeRF
RUN <<EOF
    cd ~
    mkdir -p tmp
    cd tmp
    git clone -b 2023.02 https://github.com/Nuand/bladeRF.git ./bladeRF
    cd bladeRF/host
    mkdir build
    cd build
    cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local -DINSTALL_UDEV_RULES=ON -DBLADERF_GROUP=root ../
    make
    make install
    ldconfig
    cd /opt
    # mkdir bladeRF
    # cd bladeRF
    # wget https://www.nuand.com/fx3/bladeRF_fw_v2.4.0.img
    # wget https://www.nuand.com/fpga/v0.15.3/hostedxA4.rbf
    # wget https://www.nuand.com/fpga/v0.15.3/hostedxA5.rbf
    # wget https://www.nuand.com/fpga/v0.15.3/hostedxA9.rbf
    # wget https://www.nuand.com/fpga/v0.15.3/hostedx40.rbf
    # wget https://www.nuand.com/fpga/v0.15.3/hostedx115.rbf
EOF

# install HackRF One
RUN <<EOF
    cd ~
    mkdir -p tmp
    cd tmp
    wget https://github.com/greatscottgadgets/hackrf/releases/download/v2024.02.1/hackrf-2024.02.1.tar.xz
    tar -xf hackrf-2024.02.1.tar.xz
    cd hackrf-2024.02.1/host
    mkdir build
    cd build
    cmake ..
    make
    make install
    ldconfig
EOF

# install ldc
RUN <<EOF                                    
    cd /
    mkdir -p /dlang && wget https://dlang.org/install.sh -O /dlang/install.sh
    chmod +x /dlang/install.sh
    /dlang/install.sh install -p /dlang ldc-1.39.0
    echo 'source /dlang/ldc-1.39.0/activate' >> /root/.bashrc
EOF

# copy all files from the current directory to the container /work directory
COPY . .

RUN <<EOF
    set -e
    export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/usr/local/lib
    source /dlang/ldc-1.39.0/activate
    cd /work
    dub test
    dub build --build=release
    cp /work/ezsdr /usr/bin
EOF

RUN mkdir /bundle
RUN cp -r --parents \
    /usr/bin/ezsdr \
    /usr/local/lib/libuhd.so* \
    /lib/x86_64-linux-gnu/libboost_system.so* \
    /usr/local/lib/libbladeRF.so* \
    /usr/local/lib/libhackrf.so* \
    /lib/x86_64-linux-gnu/libstdc++.so* \
    /lib/x86_64-linux-gnu/libm.so* \
    /lib/x86_64-linux-gnu/libgcc_s.so* \
    /lib/x86_64-linux-gnu/libc.so* \
    /lib/x86_64-linux-gnu/libboost_chrono.so* \
    /lib/x86_64-linux-gnu/libboost_filesystem.so* \
    /lib/x86_64-linux-gnu/libboost_serialization.so* \
    /lib/x86_64-linux-gnu/libboost_thread.so* \
    /lib/x86_64-linux-gnu/libusb-1.0.so* \
    /lib/x86_64-linux-gnu/libpython3.12.so* \
    /lib/x86_64-linux-gnu/libudev.so* \
    /lib/x86_64-linux-gnu/libz.so* \
    /lib/x86_64-linux-gnu/libexpat.so* \
    /lib/x86_64-linux-gnu/libcap.so* \
    /bundle


FROM ubuntu:24.04
COPY --from=0 /bundle /bundle
# COPY --from=0 /opt/bladeRF /opt/bladeRF
ENV LD_LIBRARY_PATH=/bundle/lib/x86_64-linux-gnu:/bundle/usr/lib/x86_64-linux-gnu:/bundle/usr/local/lib
WORKDIR /work
ENTRYPOINT ["/bundle/usr/bin/ezsdr"]
