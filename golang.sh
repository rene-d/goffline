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

    # download only godoctor and httprouter
    docker run --rm -ti -v $PWD/dl:/dl go-pkgs-dl /main.sh test

    # # try to install godoctor with Internet connection    echo
    echo "Testing Go get without Internet"
    echo

    # test compiled module
    docker run --rm -ti -v $PWD/dl:/dl --network none go-pkgs-dl sh -c \
                "/dl/go/go${GO_VERSION}-test1.sh -h; /dl/go/go${GO_VERSION}-test1.sh -m; /dl/go/go${GO_VERSION}-test1.sh; \
                echo 'package main' | godoctor godoc 2>/dev/null && echo '\033[32mtest is ok\033[0m'"

    # test build with module
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
                cat /dl/go/go${GO_VERSION}-test2.sh | sh; go build /tmp/test.go; ls -l test ; ./test"

elif [[ "$1" =~ "vscode" ]]; then
    docker run --rm -ti -v $PWD/dl:/dl ${list} go-pkgs-dl /main.sh $1

else
    list=
    if [[ -f $1 ]]; then
        list="-v $(realpath $1):/go-modules.txt:ro"
        shift
    fi
    if [[ $# == 0 ]]; then
        set -- pkgs
    fi

    docker run --rm -ti -v $PWD/dl:/dl ${list} go-pkgs-dl /main.sh $*
fi
