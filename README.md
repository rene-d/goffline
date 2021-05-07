# Goffline

How to use Go modules offline, without a GOPROXY like [Athens](https://github.com/gomods/athens) or a bunch of `git clone` and with keeping checksums verification.

## Requirements

Linux or macOS (Windows not tested) with Docker and Internet access

## Usage

Make a self-extracting archive of Go modules:

```bash
./golang.sh [list] mods
```

Make a self-extracting archive of Go modules used by the [Go extension](https://marketplace.visualstudio.com/items?itemName=golang.go) for Visual Studio Code

```bash
./golang.sh vscode-bin
```

make an archive of Visual Studio Code extensions and the remote server (for [remote development](https://code.visualstudio.com/docs/remote/remote-overview)).

```bash
./vscode.sh
```
