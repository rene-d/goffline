#!/usr/bin/env python3
# Download Visual Studio Code client and server, and a list of extensions

import argparse
import os
import requests
from pathlib import Path
import re
from dateutil.parser import parse as parsedate


def download(dest_dir: Path, urls, version):
    """Download assets."""

    session = requests.Session()

    for url in urls:
        r = session.head(url)
        if "Location" not in r.headers:
            print(r)
            continue
        real_url = r.headers["Location"]
        name = Path(real_url).name
        file = dest_dir / name

        if not file.exists():
            file.parent.mkdir(parents=True, exist_ok=True)
            print(f"downloading {file}")
            r = session.get(real_url)
            file.write_bytes(r.content)

            if int(r.headers["Content-Length"]) != file.stat().st_size:
                file.unlink()
                print(f"download problem {url}")
                exit(2)

            url_date = parsedate(r.headers["Last-Modified"])
            mtime = round(url_date.timestamp() * 1_000_000_000)
            os.utime(file, ns=(mtime, mtime))
        else:
            print(f"already downloaded: {name}")

        # the linux version name is a mess
        if re.match(r"code\-(\w+)\-x64\-(\d+)\.tar\.gz", name):
            symlink = dest_dir / f"code-linux-x64-{version}.tar.gz"
            if symlink.is_symlink() or symlink.exists():
                symlink.unlink()
            symlink.symlink_to(file.name)


def main():
    """Main function."""

    parser = argparse.ArgumentParser()
    parser.add_argument("-d", "--dest-dir", help="output dir", type=Path, default=".")
    parser.add_argument("-v", "--version", help="version", default="latest")
    parser.add_argument("--channel", help="channel", default="stable")
    args = parser.parse_args()

    ###############################################################################
    print("\n\033[1;34m🍻 Downloading VSCode\033[0m")

    print(f"Visual Studio Code: \033[1;33m{args.channel}\033[0m")

    # retrieve Windows version download link
    # ref: https://code.visualstudio.com/docs/supporting/faq#_previous-release-versions
    url = f"https://update.code.visualstudio.com/{args.version}/win32-x64-archive/{args.channel}"

    r = requests.get(url, allow_redirects=False)
    if r is None or r.status_code != 302:
        print("request error")
        exit(2)

    url = r.headers["Location"]

    # extract the commit and the version from the download link
    m = re.search(r"/(\w+)/([a-f0-9]{40})/VSCode-win32-x64-([\d.]+).zip", url)
    if not m:
        print("version not found")
        exit(2)

    channel, commit_id, version = m.groups()
    if channel != args.channel:
        print("bad channel")
        exit(2)

    print(f"Found version: \033[1;32m{version}\033[0m")
    print(f"Found commit: \033[1;32m{commit_id}\033[0m")

    # save the version (to communicate with other scripts)
    args.dest_dir.mkdir(exist_ok=True, parents=True)
    (args.dest_dir / "vscode-version").write_text(version)

    # prepare the version dependant output directory
    dest_dir = args.dest_dir / f"vscode-{version}"
    dest_dir.mkdir(exist_ok=True, parents=True)

    # save the version information
    (dest_dir / "version").write_text(f"version={version}\ncommit={commit_id}\nchannel={channel}\n")

    # the following mess is found here:
    # https://github.com/microsoft/vscode/blob/master/cli/src/update_service.rs#L224

    # https://code.visualstudio.com/docs/supporting/FAQ
    urls = [
        # archive for Windows and Linux
        f"https://update.code.visualstudio.com/{version}/win32-x64-archive/{channel}",
        f"https://update.code.visualstudio.com/{version}/linux-x64/{channel}",
        f"https://update.code.visualstudio.com/{version}/linux-deb-x64/{channel}",
        f"https://update.code.visualstudio.com/{version}/linux-deb-arm64/{channel}",
        # headless (server) for Linux (glibc)
        f"https://update.code.visualstudio.com/{version}/server-linux-x64/{channel}",
        f"https://update.code.visualstudio.com/{version}/server-linux-arm64/{channel}",
        # headless (server) for Alpine Linux (musl-libc)
        f"https://update.code.visualstudio.com/{version}/server-linux-alpine/{channel}",
        f"https://update.code.visualstudio.com/{version}/server-alpine-arm64/{channel}",
        # cli for Linux
        f"https://update.code.visualstudio.com/{version}/cli-linux-x64/{channel}",
        f"https://update.code.visualstudio.com/{version}/cli-linux-arm64/{channel}",
        f"https://update.code.visualstudio.com/{version}/cli-linux-armhf/{channel}",
        # cli for Alpine
        f"https://update.code.visualstudio.com/{version}/cli-alpine-arm64/{channel}",
        f"https://update.code.visualstudio.com/{version}/cli-alpine-x64/{channel}",
    ]

    download(dest_dir, urls, version)


if __name__ == "__main__":
    main()
