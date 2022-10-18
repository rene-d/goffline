#!/usr/bin/env python3
# Download the last Visual Studio Code extension compatible with a given version

import argparse
import json
import requests
from pathlib import Path
import os
from dateutil.parser import parse as parsedate
import re
import zipfile
import subprocess


# constants from vscode extension API
# https://github.com/microsoft/vscode/blob/main/src/vs/platform/extensionManagement/common/extensionGalleryService.ts

FilterType_Tag = 1
FilterType_ExtensionId = 4
FilterType_Category = 5
FilterType_ExtensionName = 7
FilterType_Target = 8
FilterType_Featured = 9
FilterType_SearchText = 10
FilterType_ExcludeWithFlags = 12

Flags_None = 0x0
Flags_IncludeVersions = 0x1
Flags_IncludeFiles = 0x2
Flags_IncludeCategoryAndTags = 0x4
Flags_IncludeSharedAccounts = 0x8
Flags_IncludeVersionProperties = 0x10
Flags_ExcludeNonValidated = 0x20
Flags_IncludeInstallationTargets = 0x40
Flags_IncludeAssetUri = 0x80
Flags_IncludeStatistics = 0x100
Flags_IncludeLatestVersionOnly = 0x200
Flags_Unpublished = 0x1000
Flags_IncludeNameConflictInfo = 0x8000


def get_property(version, name):
    if "properties" not in version:
        # print(version)
        return
    for property in version["properties"]:
        if property["key"] == name:
            return property["value"]
    return


def version_serial(version):
    v = version.split(".", maxsplit=2)
    if "-" in v[2]:
        r = v[2].split("-", maxsplit=1)
        t = (int(v[0]), int(v[1]), int(r[0]), r[1])
        return t
    else:
        return tuple(map(int, v))


def engine_match(pattern, engine):

    if pattern == "*":
        return True

    if pattern[0] != "^":
        if pattern == "0.10.x" or pattern.endswith("-insider"):
            return False
        # print("missing caret:", pattern)
        return False

    assert pattern[0] == "^"

    def rr():
        p = version_serial(pattern[1:])
        v = version_serial(engine)

        if len(p) == 4 and p[3] == "insiders":
            return False

        if p[0] != v[0]:  # major must be the same
            return False
        if p[1] > v[1]:  # minor must be greater or equal
            return False
        if p[1] == v[1] and p[2] != 0 and p[2] > v[2]:
            return False

        return True

    r = rr()
    # print(pattern, engine, r)
    return r


class Extension:
    def __init__(self, engine, verbose=False):
        self.engine = engine
        self.verbose = verbose

    def run(self, dest_dir, slugs):
        """Download all extensions and packs."""

        self.all_extensions = set()

        self._get_downloads(slugs)
        self._download_files(dest_dir)

        while self.packs:
            new_extensions = set()

            for vsix in self.downloads:
                if vsix in self.packs:
                    zip = zipfile.ZipFile(dest_dir / vsix)
                    m = json.loads(zip.open("extension/package.json").read())
                    new_extensions.update(m["extensionPack"])
                    zip.close()

            new_extensions.difference_update(self.all_extensions)

            self._get_downloads(new_extensions)
            self._download_files(dest_dir)

    def _download_files(self, dest_dir):
        """Download extesions archive (VSIX)."""
        for k, v in self.downloads.items():
            vsix = dest_dir / k
            if not vsix.exists():
                vsix.parent.mkdir(parents=True, exist_ok=True)
                print("downloading", vsix)
                r = requests.get(v[2])
                vsix.write_bytes(r.content)

                url_date = parsedate(v[3])
                mtime = round(url_date.timestamp() * 1_000_000_000)
                os.utime(vsix, ns=(mtime, mtime))
            else:
                print(f"already downloaded: {vsix.name}")

    def _get_downloads(self, slugs):
        """Build the extension list to download."""
        self.downloads = {}
        self.packs = set()
        if not slugs:
            return
        r = self._query(slugs)
        for result in r["results"]:
            for extension in result["extensions"]:
                vsix = self._get_download(extension)
                if vsix:
                    if "Extension Packs" in extension["categories"]:
                        self.packs.update(vsix)

                    self.all_extensions.update(vsix)

    def _query(self, slugs):
        """
        Prepare the request tp the extension server, with::
           - assets uri (Flags.IncludeAssetUri)
           - details (Flags.IncludeVersionProperties)
           - categories (Flags.IncludeCategoryAndTags)
        """
        data = {
            "filters": [
                {
                    "criteria": [
                        {
                            "filterType": FilterType_Target,
                            "value": "Microsoft.VisualStudio.Code",
                        },
                        {
                            "filterType": FilterType_ExcludeWithFlags,
                            "value": str(Flags_Unpublished),
                        },
                        # {
                        #     "filterType": FilterType_ExtensionName,
                        #     "value": args.slug,
                        # },
                    ]
                }
            ],
            "flags": Flags_IncludeAssetUri + Flags_IncludeVersionProperties + Flags_IncludeCategoryAndTags,
        }

        for slug in slugs:
            data["filters"][0]["criteria"].append({"filterType": FilterType_ExtensionName, "value": slug})

        data = json.dumps(data)

        r = requests.post(
            "https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery",
            data=data,
            headers={
                "Content-Type": "application/json",
                "Accept": "application/json;api-version=3.0-preview.1",
            },
        )
        if self.verbose:
            Path("query.json").write_text(data)
            Path("response.json").write_bytes(r.content)
        r = r.json()
        # r = json.load(open("response.json"))
        return r

    def _get_download(self, extension):

        name = extension["publisher"]["publisherName"] + "." + extension["extensionName"]

        def filter_version(extension, platform):
            has_target_platform = set()

            for version in extension["versions"]:
                # sanity check
                if version["flags"] != "validated" and version["flags"] != "none":
                    print("flags should be 'validated' or 'none'")
                    print(json.dumps(version, indent=2))
                    exit()

                # do not use pre-release version
                v = get_property(version, "Microsoft.VisualStudio.Code.PreRelease")
                if v == "true":
                    continue

                # we have to match the engine version
                v = get_property(version, "Microsoft.VisualStudio.Code.Engine")
                if not (v and engine_match(v, self.engine)):
                    continue

                if version.get("targetPlatform") != None:
                    has_target_platform.add(version["version"])

                # we have to match the platform if asked and specified for the version
                if version["version"] in has_target_platform and platform and version.get("targetPlatform") != platform:
                    continue

                yield version

        def find_latest_version(extension, platform):
            versions = filter_version(extension, platform)
            versions = sorted(versions, key=lambda v: version_serial(v["version"]))
            if versions:
                return versions[-1]

        def find_version_vsix(extension, platform):
            version = find_latest_version(extension, platform)

            if name == "vadimcn.vscode-lldb":
                if "alpine" in platform:
                    return

                os, arch = platform.split("-")
                # cf. extension/package.json of the generic extension
                arch = {"x64": "x86_64", "arm64": "aarch64"}.get(arch)
                asset_uri = f"https://github.com/vadimcn/vscode-lldb/releases/download/v{version['version']}/codelldb-{arch}-{os}.vsix"
                target_platform = platform

            else:
                if not version:
                    print(f"missing {platform} for {name}")
                    return
                asset_uri = version["assetUri"] + "/Microsoft.VisualStudio.Services.VSIXPackage"
                target_platform = version.get("targetPlatform")

            if target_platform:
                vsix = name + "-" + target_platform + "-" + version["version"] + ".vsix"
            else:
                vsix = name + "-" + version["version"] + ".vsix"

            download = (
                version["version"],
                get_property(version, "Microsoft.VisualStudio.Code.Engine"),
                asset_uri,
                version["lastUpdated"],
            )

            if vsix in self.downloads:
                assert self.downloads[vsix] == download

            self.downloads[vsix] = download
            return vsix

        vsix = set()
        vsix.add(find_version_vsix(extension, "linux-x64"))
        vsix.add(find_version_vsix(extension, "linux-arm64"))
        vsix.add(find_version_vsix(extension, "alpine-x64"))
        vsix.add(find_version_vsix(extension, "alpine-arm64"))
        return vsix


def vscode_latest_version(channel="stable"):
    """Retrieve current VSCode version from Windows download link."""

    url = f"https://code.visualstudio.com/sha/download?build={channel}&os=win32-x64-archive"
    r = requests.get(url, allow_redirects=False)
    if r is None or r.status_code != 302:
        print(f"request error {r}")
        exit(2)

    url = r.headers["Location"]
    m = re.search(r"/(\w+)/([a-f0-9]{40})/VSCode-win32-x64-([\d.]+).zip", url)
    if not m or m[1] != channel:
        print(f"cannot extract vscode version from url {url}")
        exit(2)

    _, commit_id, version = m.groups()
    print(f"Using VSCode {version} {commit_id} {channel}")
    return version, commit_id


def check_local(slugs):
    """
    Compare the list of desired extensions with the list of locally installed extensions.
    """
    set_installed = set(subprocess.check_output(["code", "--list-extensions"]).decode().split())
    set_wanted = set(slugs)

    # check the case
    set_installed_lowercase = set(map(str.lower, set_installed))
    for i in set_wanted:
        if i in set_installed:
            continue
        if i.lower() in set_installed_lowercase:
            for j in set_installed:
                if j.lower() == i.lower():
                    print(f"Upper/lower case problem with {i}, should be {j}")
            return 2

    set3 = set_wanted.union(set_installed)
    color_wanted = "95"
    color_installed = "93"
    extension, color, a, b = "extension", "37", "wanted", "installed"
    print(f"\033[1;3;{color}m{extension:<55}\033[{color_wanted}m{a:^9}\033[{color_installed}m{b:^9}\033[0m")

    for extension in sorted(set3):
        a = extension in set_wanted
        b = extension in set_installed
        color = "37"
        if not a and b:
            color = color_installed
        if a and not b:
            color = color_wanted
        a = "❌✅"[a]
        b = "❌✅"[b]

        # see explaination here:
        # https://wezfurlong.org/wezterm/hyperlinks.html#explicit-hyperlinks
        link = f"\033]8;;https://marketplace.visualstudio.com/items?itemName={extension}\033\\{extension}\033]8;;\033\\"
        link += " " * (55 - len(extension))

        print(f"\033[{color}m{link}\033[0m{a:^9}{b:^9}")

    return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("-v", "--verbose", help="verbose and debug info", action="store_true")
    parser.add_argument("-d", "--dest-dir", help="output dir", type=Path, default=".")
    parser.add_argument("-e", "--engine", help="engine version", default="current")
    parser.add_argument("-c", "--config", help="conf file", type=Path)
    parser.add_argument("--check-local", help=argparse.SUPPRESS, action="store_true")
    parser.add_argument("slugs", help="extension identifier", nargs="*")
    args = parser.parse_args()

    if args.config:
        in_section = False
        for i in args.config.read_text().splitlines():
            i = i.strip()
            if not i or i.startswith("#"):
                continue
            if i.startswith("["):
                in_section = i.startswith("[vscode")
            else:
                if in_section:
                    args.slugs.append(i)

    if args.check_local:
        exit(check_local(args.slugs))

    if args.engine == "latest":
        args.engine, _ = vscode_latest_version()
    elif args.engine == "current":
        args.engine = (args.dest_dir / "vscode-version").read_text().strip()
        print(f"Using vscode {args.engine}")

    dest_dir = args.dest_dir / f"vscode-extensions-{args.engine}"
    dest_dir.mkdir(exist_ok=True, parents=True)

    e = Extension(args.engine, args.verbose)
    e.run(dest_dir, args.slugs)


if __name__ == "__main__":
    main()
