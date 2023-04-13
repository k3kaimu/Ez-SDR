export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y curl file gcc wget python3 python3-pip
apt install -y autoconf automake build-essential ccache cmake cpufrequtils doxygen ethtool \
    g++ git inetutils-tools libboost-all-dev libncurses5 libncurses5-dev libusb-1.0-0 libusb-1.0-0-dev \
    libusb-dev python3-dev python3-mako python3-numpy python3-requests python3-scipy python3-setuptools \
    python3-ruamel.yaml libboost-all-dev
pip3 install mako
# git clone https://github.com/xianyi/OpenBLAS.git
# cd OpenBLAS
# make
# make install PREFIX=/opt/OpenBLAS
# echo 'export LD_LIBRARY_PATH=/opt/OpenBLAS/lib:$LD_LIBRARY_PATH' >> /root/entrypoint_shellenv.sh

# Install dlang
cd ~
mkdir -p ~/dlang && wget https://dlang.org/install.sh -O ~/dlang/install.sh
chmod +x ~/dlang/install.sh
~/dlang/install.sh install ldc-1.31.0
echo 'source ~/dlang/ldc-1.31.0/activate' >> /root/entrypoint_shellenv.sh
echo 'source ~/entrypoint_shellenv.sh' >> /root/.bashrc

# Install uhd
cd ~
mkdir tmp
cd tmp
wget https://github.com/EttusResearch/uhd/archive/refs/tags/v4.1.0.5.tar.gz
tar -xf v4.1.0.5.tar.gz
cd uhd-4.1.0.5/host
mkdir build
cd build
cmake -DCMAKE_FIND_ROOT_PATH=/usr ../
make
make test
make install
echo 'export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/usr/local/lib' >> /root/entrypoint_shellenv.sh
