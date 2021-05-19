#!/usr/bin/env bash

if [[ $# != 2 ]]; then
    echo "Usage: $0 <file1.sh> <file2.sh>"
    echo
    echo "Compare two downloaded module list"
else
    diff <("$1" -t | sort -u) <("$2" -t | sort -u) | sed -nr '/@/s/(^[^@]+@v[^/]+).*$/\1/p' | grep -v "sumdb/sum\.golang\.org" | uniq
fi
