#!/usr/bin/env python3
import os
import platform

def get_version():
    with open("Cargo.toml") as fh:
        for line in fh:
            if line.startswith("version"):
                return line.replace("version", "").replace("=", "").replace('"', '').strip()
    return ''

if __name__ == '__main__':
    # check version
    version = get_version()
    machine = platform.uname().machine
    os.chdir("appimage")
    os.system(f"sed 's/^Version=.*/Version={version}/g' ../res/rustdesk.desktop >rustdesk.desktop")
    os.system(f"sed -i 's/^    version: .*/    version: {version}/g' AppImageBuilder-{machine}.yml")
    # build appimage
    ret = os.system("appimage-builder --recipe AppImageBuilder-x86_64.yml --skip-test")
    if ret == 0:
        print("RustDesk AppImage build success :)")
        print(f"Check AppImage in '{os.getcwd()}/rustdesk-{version}-{machine}.AppImage'")
    else:
        print("RustDesk AppImage build failed :(")
