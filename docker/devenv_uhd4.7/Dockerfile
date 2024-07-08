FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN <<EOF
    apt update
    apt install -y curl file gcc wget python3 python3-pip \
        autoconf automake build-essential ccache cmake cpufrequtils doxygen ethtool \
        g++ git inetutils-tools libboost-all-dev libncurses-dev libusb-1.0-0 libusb-1.0-0-dev \
        libusb-dev python3-dev python3-mako python3-numpy python3-requests python3-scipy python3-setuptools \
        python3-ruamel.yaml libboost-all-dev nlohmann-json3-dev clang
EOF

SHELL ["/bin/bash", "-c"]

RUN <<EOF
    cd ~
    mkdir tmp
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
    echo 'export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/usr/local/lib' >> /root/entrypoint_shellenv.sh
EOF

RUN <<EOF                                    
    cd /
    mkdir -p /dlang && wget https://dlang.org/install.sh -O /dlang/install.sh
    chmod +x /dlang/install.sh
    /dlang/install.sh install -p /dlang ldc-1.31.0
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
