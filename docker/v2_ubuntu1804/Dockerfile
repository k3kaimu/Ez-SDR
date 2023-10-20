FROM ubuntu:18.04

ENV DEBIAN_FRONTEND=noninteractive

RUN <<EOF
    apt update
    apt install -y libuhd-dev wget git
EOF

SHELL ["/bin/bash", "-c"]

RUN <<EOF                                    
    cd /
    mkdir -p /dlang && wget https://dlang.org/install.sh -O /dlang/install.sh
    chmod +x /dlang/install.sh
    /dlang/install.sh install -p /dlang ldc-1.31.0
EOF

RUN <<EOF
    source /dlang/ldc-1.31.0/activate
    ch /
    mkdir workdir
    cd workdir
    git clone https://github.com/k3kaimu/uhd4d.git
    git clone https://github.com/k3kaimu/multiusrp.git -b v2.0
    cd multiusrp
    dub build --compiler=ldc2
    cp multiusrp /usr/bin
    cd /
    rm -rf workdir
EOF
