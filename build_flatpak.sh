#!/bin/bash -e

# This script packages a FlatPak based on the results of building in the "ubuntu" chroot.

PATH=${PWD}/.cargo/bin:${HOME}/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ROOTDIR="${PWD}/ubuntu"

# Build the FlatPak
unmountFuserMountFlatPak() {
  # flatpak-builder loves leaving behind fuser mounts that can't be unmounted
  # for a while. But if left around, these mounts tend to break future builds.
  local mounts="$(
    awk "/${ROOTDIR//\//\\\/}${PWD//\//\\\/}\/.flatpak-builder/{ print \$2 }" \
         /proc/mounts)"
  for _ in `seq 10`; do
    mounts="$(for i in ${mounts}; do
      fusermount3 -uz "${i}" >&/dev/null || echo "${i}"
    done)"
    [ -n "${mounts}" ] || return
    sleep 1
  done
}

unmountFuserMountFlatPak &
( cd "${ROOTDIR}${PWD}"
  PATH="${PATH//:/:${ROOTDIR}}:${PATH}"
  git submodule add https://github.com/flathub/shared-modules.git \
      2>/dev/null || :
  export FLATPAK_USER_DIR=${ROOTDIR}/${HOME}/.local/share/flatpak
  export FLATPAK_CONFIG_DIR=${ROOTDIR}/etc/flatpak
  rm -rf .flatpak-builder || :
  rm flatpak/shared-modules >&/dev/null || :
  ln -sf ../shared-modules flatpak/ || :
  mkdir -p target/repo
  flatpak remote-add --user --if-not-exists flathub \
          https://flathub.org/repo/flathub.flatpakrepo
  flatpak-builder --user --force-clean --install-deps-from=flathub \
                  --repo=target/repo target/flatpak flatpak/rustdesk.json
  img="rustdesk-$(sed 's/.*rustdesk-\([0-9].*\)\.deb.*/\1/;t1;d;:1;q' flatpak/rustdesk.json)-$(uname -i).flatpak"
  flatpak build-bundle target/repo "${img}" com.rustdesk.RustDesk
  [ -r "${PWD}/${img}" ] &&
  cp -alf "${PWD}/${img}" "${ROOTDIR%/*}/${img}" || :)
unmountFuserMountFlatPak &

exit 0
