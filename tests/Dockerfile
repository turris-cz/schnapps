FROM alpine:latest

ENV HOME=/root

RUN apk --update add wget git bash sudo ncurses btrfs-progs util-linux-misc coreutils tar gpg

# Get the newer release then the one available in Alpine
RUN cd /root && wget -O - https://github.com/bats-core/bats-core/archive/refs/tags/v1.6.0.tar.gz | tar -xzf - && cd bats-core-* && ./install.sh /usr

RUN cd /root && mkdir bats && cd bats && for i in bats-file bats-assert bats-support; do git clone https://github.com/bats-core/$i.git; done


