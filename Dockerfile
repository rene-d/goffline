ARG GOLANG_VERSION

FROM golang:${GOLANG_VERSION}

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get -qq update && \
    apt-get -qq upgrade -y && \
    apt-get -qq install -y --no-install-recommends jq curl git vim sudo unzip xz-utils bzip2 python3-requests python3-dateutil

COPY *.sh *.py config.txt /

ENV DESTDIR=/dl
RUN go version