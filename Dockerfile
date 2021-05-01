ARG GO_VERSION=1.14.15

FROM golang:${GO_VERSION}-buster

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y --no-install-recommends jq curl git vim sudo lzma unzip xz-utils bzip2

COPY *.sh go-modules.txt /

ENV DESTDIR=/dl
