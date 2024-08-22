FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN <<EOF
    apt update
    apt install -y curl file gcc wget python3 python3-pip \
        autoconf automake build-essential ccache cmake cpufrequtils doxygen ethtool pkg-config \
        g++ git inetutils-tools libboost-all-dev libncurses-dev libusb-1.0-0 libusb-1.0-0-dev \
        libusb-dev python3-dev python3-mako python3-numpy python3-requests python3-scipy python3-setuptools \
        python3-ruamel.yaml libboost-all-dev nlohmann-json3-dev clang gdb libfftw3-dev
EOF

SHELL ["/bin/bash", "-c"]

# install UHD
RUN <<EOF
    cd ~
    mkdir -p tmp
    cd tmp
    wget https://github.com/EttusResearch/uhd/archive/refs/tags/v4.7.0.0.tar.gz
    tar -xf v4.7.0.0.tar.gz
    cd uhd-4.7.0.0/host
    mkdir build
    cd build
    cmake -DCMAKE_FIND_ROOT_PATH=/usr ../
    JOBS=$(($(grep cpu.cores /proc/cpuinfo | sort -u | sed 's/[^0-9]//g') + 1))
    make -j${JOBS}
    make test
    make install
    echo 'export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/usr/local/lib' >> /root/.bashrc
EOF

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
    mkdir bladeRF
    cd bladeRF
    wget https://www.nuand.com/fx3/bladeRF_fw_v2.4.0.img
    wget https://www.nuand.com/fpga/v0.15.3/hostedxA4.rbf
    wget https://www.nuand.com/fpga/v0.15.3/hostedxA5.rbf
    wget https://www.nuand.com/fpga/v0.15.3/hostedxA9.rbf
    wget https://www.nuand.com/fpga/v0.15.3/hostedx40.rbf
    wget https://www.nuand.com/fpga/v0.15.3/hostedx115.rbf
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

# RUN <<EOF
#     source /dlang/ldc-1.31.0/activate
#     ch /
#     mkdir workdir
#     cd workdir
#     git clone https://github.com/k3kaimu/uhd4d.git
#     git clone https://github.com/k3kaimu/multiusrp.git -b v2.0
#     cd multiusrp
#     dub build --compiler=ldc2
#     cp multiusrp /usr/bin
#     cd /
#     rm -rf workdir
# EOF
