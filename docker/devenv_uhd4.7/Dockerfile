FROM ghcr.io/k3kaimu/uhd:v4.7

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
