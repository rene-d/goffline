# Goffline

[![CI](https://github.com/rene-d/goffline/actions/workflows/go_test.yml/badge.svg)](https://github.com/rene-d/goffline/actions/workflows/go_test.yml)

How to use Go modules offline, without a GOPROXY like [Athens](https://github.com/gomods/athens) or a bunch of `git clone` and with keeping [checksums verification](https://sum.golang.org).

Binaries for both architectures `amd64` and `arm64` are built during the download step, and the right one extracted during the installation step.

## Requirements

Linux or macOS (Windows not tested) with Docker, bash and Internet access.

## Usage

Make a self-extracting archive of Go modules:

```bash
./golang.sh [-f module_list] [options]
```

The result will be two files:

- `mods-[Go version]-[timestamp].sh` : the self-extracting archive (with a few command-line options)
- `mods-[Go version]-[timestamp].sh.sha256` : optional archive checksum

Make a self-extracting archive of Go modules used by the [Go extension](https://marketplace.visualstudio.com/items?itemName=golang.go) for Visual Studio Code (only the compiled binaries, seems to be sufficient):

```bash
./golang.sh vscode
```

Nota: the program tries to dermine the needed tools, that is pretty difficult and hazardous. It tries to analyse the [goToolsInformation.go](https://github.com/golang/vscode-go/blob/master/src/goToolsInformation.ts), but without making the sophisticated checks of versions and needs.

Download current stable version of [Visual Studio Code](https://code.visualstudio.com), some extensions and the remote server (for [remote development](https://code.visualstudio.com/docs/remote/remote-overview)):

```bash
./vscode.sh [extension list]
```

## Configuration

See [config.txt](./config.txt) for an example of module and extension list.

## Test

There is a unit test for Go downloads, run into a container with no Internet access (`--network none`).
