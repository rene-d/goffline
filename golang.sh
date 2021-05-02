#!/usr/bin/env bash

set -e

GO_VERSION=${GO_VERSION:-1.14.15}

DOCKER_SCAN_SUGGEST=false docker build --build-arg GO_VERSION=${GO_VERSION} -t go-pkgs-dl .

mkdir -p $PWD/dl

if [[ "$1" == "build_only" ]]; then
    exit

elif [[ "$1" == "shell" ]]; then
    exec docker run --rm -ti -v $PWD:/wd -w /wd go-pkgs-dl

elif [[ "$1" == "test" ]]; then
    rm -f dl/go/test[12].*

    # download only godoctor and httprouter
    docker run --rm -ti -v $PWD/dl:/dl go-pkgs-dl /main.sh test

    # # try to install godoctor with Internet connection    echo
    echo "Testing Go without Internet connection"
    echo

    # test compiled module
    docker run --rm -ti -v $PWD/dl:/dl --network none go-pkgs-dl sh -c \
                "/dl/go/test1.sh -h;
                 /dl/go/test1.sh -i;
                 /dl/go/test1.sh -m;
                 /dl/go/test1.sh;
                 hello && echo '\033[32mtest is ok\033[0m'"

    # test build with module (in GOPATH mode)
    (cat <<'EOF'
package main

import (
    "fmt"
    "net/http"
    "github.com/julienschmidt/httprouter"
)

func Index(w http.ResponseWriter, r *http.Request, _ httprouter.Params) {
    fmt.Fprint(w, "Welcome!\n")
}

func main() {
    router := httprouter.New()
    router.GET("/", Index)
    fmt.Println("\033[32mtest is ok\033[0m")
}
EOF
) | docker run --rm -i -v $PWD/dl:/dl --network none go-pkgs-dl sh -c "cat > /tmp/test.go ; \
                cat /dl/go/test2.sh | sh; go build /tmp/test.go; ls -l test ; ./test"

elif [[ "$1" =~ "vscode" ]]; then
    docker run --rm -ti -v $PWD/dl:/dl ${list} go-pkgs-dl /main.sh $1

else
    list=
    if [[ -f $1 ]]; then
        list="-v $(realpath $1):/config.txt:ro"
        shift
    fi
    if [[ $# == 0 ]]; then
        set -- pkgs
    fi

    docker run --rm -ti -v $PWD/dl:/dl ${list} go-pkgs-dl /main.sh $*
fi
