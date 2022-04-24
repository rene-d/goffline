#!/usr/bin/env python3
# Download the last Visual Studio Code extension compatible with a given version

import argparse
import json
import requests
from pathlib import Path
import os
from dateutil.parser import parse as parsedate


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
    def __init__(self, engine):
        self.engine = engine
        self.downloads = {}

    def _query(self, slugs):
        # prepare the request: we look for golang.Go extension
        #   - last version (Flags.IncludeLatestVersionOnly)
        #   - we want the assets uri (Flags.IncludeAssetUri)
        #   - details (Flags.IncludeVersionProperties)
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
            "flags": Flags_IncludeAssetUri + Flags_IncludeVersionProperties,
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
        # Path("r.json").write_bytes(r.content)
        r = r.json()
        # r = json.load(open("r.json"))
        return r

    def get_downloads(self, slugs):
        r = self._query(slugs)
        for result in r["results"]:
            for extension in result["extensions"]:
                self._get_download(extension)

    def _get_download(self, extension):

        name = extension["publisher"]["publisherName"] + "." + extension["extensionName"]

        def filter_version(extension, platform):
            for version in extension["versions"]:
                if version["flags"] != "validated" and version["flags"] != "none":
                    print(json.dumps(version, indent=2))
                    exit()
                if version.get("targetPlatform", platform) != platform:
                    continue
                v = get_property(version, "Microsoft.VisualStudio.Code.PreRelease")
                if v == "true":
                    continue
                v = get_property(version, "Microsoft.VisualStudio.Code.Engine")
                if v and engine_match(v, self.engine):
                    yield version

        def find_version(extension, platform):
            versions = filter_version(extension, platform)

            versions = sorted(versions, key=lambda v: version_serial(v["version"]))
            version = versions[-1]

            asset_uri = version["assetUri"] + "/Microsoft.VisualStudio.Services.VSIXPackage"
            target_platform = version.get("targetPlatform")

            if name == "vadimcn.vscode-lldb":
                os, arch = platform.split("-")
                arch = {"x64": "x86_64", "arm64": "aarch64"}[arch]
                asset_uri = f"https://github.com/vadimcn/vscode-lldb/releases/download/v{version['version']}/codelldb-{arch}-{os}.vsix"
                target_platform = platform

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

        find_version(extension, "linux-x64")
        find_version(extension, "linux-arm64")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("-o", "--output", help="output dir", type=Path, default=".")
    parser.add_argument("-e", "--engine", help="engine version", default="1.66.2")
    parser.add_argument("-f", "--conf", help="conf file", type=Path)
    parser.add_argument("slugs", help="extension identifier", nargs="*")
    args = parser.parse_args()

    if args.conf:
        in_section = False
        for i in args.conf.read_text().splitlines():
            i = i.strip()
            if not i or i.startswith("#"):
                continue
            if i.startswith("["):
                in_section = i.startswith("[vscode")
            else:
                if in_section:
                    args.slugs.append(i)

    e = Extension(args.engine)
    e.get_downloads(args.slugs)
    for k, v in e.downloads.items():
        vsix = args.output / k
        if not vsix.exists():
            vsix.parent.mkdir(parents=True, exist_ok=True)
            print("downloading", vsix)
            r = requests.get(v[2])
            vsix.write_bytes(r.content)

            url_date = parsedate(v[3])
            mtime = round(url_date.timestamp() * 1_000_000_000)
            os.utime(vsix, ns=(mtime, mtime))


if __name__ == "__main__":
    main()
