FROM ezsdr_dev:3.0.0

ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-c"]

RUN <<EOF
    export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/usr/local/lib
    source /dlang/ldc-1.39.0/activate
    cd ~
    git clone https://github.com/k3kaimu/Ez-SDR.git  ./ezsdr
    cd ezsdr
    dub build --build=release
    cp ./ezsdr /usr/bin
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
COPY --from=0 /opt/bladeRF /opt/bladeRF
ENV LD_LIBRARY_PATH=/bundle/lib/x86_64-linux-gnu:/bundle/usr/lib/x86_64-linux-gnu:/bundle/usr/local/lib
WORKDIR /work
CMD ["/bundle/usr/bin/ezsdr"]