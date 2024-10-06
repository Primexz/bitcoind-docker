ARG BTCD_VERSION
ARG ARCH

ARG VER_ALPINE=3.20
ARG USER=bitcoind
ARG DIR=/data

## ----- VERIFICATION STAGE ----- ##

FROM ${ARCH:+${ARCH}/}alpine:${VER_ALPINE} AS verifier

# consume the variable
ARG BTCD_VERSION
ARG ARCHIVE_NAME=bitcoin-$BTCD_VERSION.tar.gz

RUN apk add --no-cache \
    gnupg \
    curl \
    jq

# checksums
ADD https://bitcoincore.org/bin/bitcoin-core-$BTCD_VERSION/SHA256SUMS.asc ./
ADD https://bitcoincore.org/bin/bitcoin-core-$BTCD_VERSION/SHA256SUMS ./

# source code
ADD https://bitcoincore.org/bin/bitcoin-core-$BTCD_VERSION/${ARCHIVE_NAME} ./${ARCHIVE_NAME}

# import gpg keys
RUN  curl -s "https://api.github.com/repos/bitcoin-core/guix.sigs/contents/builder-keys" | \
    jq -r '.[].download_url' | \
    xargs -I {} sh -c 'curl -sL "{}" -o "$(basename {})" && gpg --import "$(basename {})" && rm "$(basename {})"'

RUN gpg --list-keys

# verify the hashes with our imported gpg keys
RUN gpg --verify SHA256SUMS.asc SHA256SUMS

# verify the source code
RUN grep "${ARCHIVE_NAME}" SHA256SUMS | sha256sum -c

# extract the source code
RUN tar -xzf "${ARCHIVE_NAME}" && \
    rm -f "${ARCHIVE_NAME}"

RUN ls -lah


## ----- BUILD STAGE ----- ##

FROM ${ARCH:+${ARCH}/}alpine:${VER_ALPINE} AS builder

# consume the variable
ARG BTCD_VERSION
ENV BITCOIN_PREFIX /opt/bitcoin-$BTCD_VERSION

COPY --from=verifier /bitcoin-$BTCD_VERSION /bitcoin-$BTCD_VERSION
WORKDIR /bitcoin-$BTCD_VERSION

RUN apk add --no-cache \
    autoconf \
    automake \
    boost-dev \
    sqlite-dev \
    build-base \
    chrpath \
    file \
    libevent-dev \
    libressl \
    libtool \
    linux-headers \
    zeromq-dev

RUN ./autogen.sh

RUN ./configure LDFLAGS=-L/opt/db4/lib/ CPPFLAGS=-I/opt/db4/include/ \ 
    CXXFLAGS="-O2" \
    --prefix="$BITCOIN_PREFIX" \
    --disable-man \
    --disable-shared \
    --disable-tests \
    --disable-gui-tests \
    --disable-bench \
    --enable-static \
    --enable-reduce-exports \
    --without-gui \
    --without-libs \
    --with-utils \
    --with-sqlite=yes \
    --with-daemon

RUN make -j$(( $(nproc) )) -v
RUN make install

RUN strip -v "$BITCOIN_PREFIX/bin/bitcoin"*
RUN sha256sum "$BITCOIN_PREFIX/bin/bitcoin"*

## ----- FINAL STAGE ----- ##

FROM ${ARCH:+${ARCH}/}alpine:${VER_ALPINE} AS final

ARG BTCD_VERSION
ARG USER
ARG DIR

RUN apk add --no-cache \
    libevent \
    libsodium \
    libstdc++ \
    libzmq \
    sqlite-libs

COPY --from=builder /opt/bitcoin-$BTCD_VERSION/bin/bitcoin*  /usr/local/bin/

RUN adduser --disabled-password \
    --home "$DIR/" \
    --gecos "" \
    "$USER"

USER $USER

RUN mkdir -p "$DIR/.bitcoin/"

VOLUME $DIR/.bitcoin/

# rest ports
EXPOSE 8080

# p2p ports
EXPOSE 8333 18333 18444

# rpc ports
EXPOSE 8332 18332 18443

# zmq ports
EXPOSE 28332 28333

ENTRYPOINT ["bitcoind"]

CMD ["-zmqpubrawblock=tcp://0.0.0.0:28332", "-zmqpubrawtx=tcp://0.0.0.0:28333"]