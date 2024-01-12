#!/bin/bash -e

# "rustdesk" is surprisingly difficult to build. Not because the build-process
# is difficult per se, but because it has a lot of dependencies and that
# makes it challenging to set up the required build environment with all the
# necessary system-wide tools. Also, the order in which dependencies are
# installed matters, and in some cases, obscure command line options are
# required to configure things just right.
#
# And that's just for building the native *.deb file. If you want to build
# and AppImage or FlatPak, you'll have to add an entirely different set of
# sublty interconnected fragile components.
#
# This script is meant to run on Ubuntu (and possibly other Debian-like
# systems) and it side-steps the challenges to the system-wide configuration
# changes by installing a fresh Ubuntu distribution in a sub-directory that is
# then accessed with the "fakechroot" tool.


# Set up a reasonable and standardized environment, so that we can control
# execution of the script and of expected input/output from shell commands.
PATH=${PWD}/.cargo/bin:${HOME}/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
LC_ALL=C

# Define what our simulated environment looks like.
DIST=jammy
ROOTDIR="${PWD}/ubuntu"
HOMEDIR="${ROOTDIR}${HOME}"
DEBDEP="clang cmake curl g++ flatpak-builder gcc git nasm libarchive-tools \
        libasound2-dev libfuse3-dev libgstreamer1.0-dev \
        libgstreamer-plugins-base1.0-dev libgtk-3-dev libpulse-dev \
        libva-dev libvdpau-dev libxcb-randr0-dev libxcb-shape0-dev \
        libxcb-xfixes0-dev libxdo-dev libxfixes-dev tar unzip wget \
        yasm zip"

# Checks whether a particular Debian package is already installed
is_installed() {
  $2 dpkg -l "$1" 2>/dev/null | grep '^ii ' >&/dev/null || return 1
}

# Runs a command as root. This is similar to "sudo", but executes in a
# simulated environment without needing elevated privileges. It operates
# on the Ubuntu distribution that we installed inside of the "ubuntu"
# directory. "runasroot" is needed to install system components into this
# distribution.
runasroot() {
  fakechroot fakeroot chroot "${ROOTDIR}" "$@"
}

# Similarly to "runasroot", this command runs as the default user. It can
# optionally change the execution directory if the "-d" option has been
# passed in. Otherwise, it will operate inside of the source directory, which
# is identical to the current working directory outside of the chroot
# environment.
# N.B. While both "fakechroot" and "fakeroot" are very powerful commands,
# unlike a "real" chroot jail or preferably a container, they make it trivial
# to escape the simulated environment. This can even happen accidentally
# and that can break the build process. By copying the same directory hierarchy
# inside of the simulated environment as what we have in the host system,
# we mitigate the impact of when that happens.
runasuser() {
  local dir="${PWD}"
  if [ "x$1" = "x-d" ]; then
    dir="$2"
    [ "x${dir#/}" != "x${dir}" ] || dir="${PWD}/${dir}"
    shift; shift
  fi
  fakechroot -s chroot "${ROOTDIR}" sh -c "cd \"${dir}\" && \"\$0\" \"\$@\"" "$@"
}

# We need a minimum number of tools on the host system in order to run.
# These tools should be installed system-wide, so we have to invoke "sudo",
# which might prompt the user for a password. This will only happen the first
# time this script runs.
for p in debootstrap fakeroot fakechroot flatpak-builder; do
  is_installed "${p}" || sudo apt install -y "${p}"
done

# If the "ubuntu" directory doesn't already exist, install an Ubuntu
# distribution into the simulated environment.
[ -d "${ROOTDIR}/bin" ] || fakechroot fakeroot debootstrap "${DIST}" "${ROOTDIR}"
for i in universe multiverse; do
  mkdir -p "${ROOTDIR}/etc/apt/sources.list.d/"
  sed "s/main/${i}/" "${ROOTDIR}/etc/apt/sources.list" \
      >"${ROOTDIR}/etc/apt/sources.list.d/${i}.list"
done

# Replicate parts of the directory hierarchy of the host in the simulated
# environment. In particular, we need the user's home directory and the
# path all the way to where the source files reside.
[ -d "${HOMEDIR}" ] || {
   runasroot groupadd -g $(id -g) "${USER}" || :
   runasroot useradd -g $(id -g) -u $(id -u) -d "${HOME}" -m "${USER}" || :
   mkdir -p "${ROOTDIR}${PWD}"
   for i in .cargo target vcpkg; do
     [ -h "${i}" ] || {
       rm -rf "${i}"
       ln -sf "${ROOTDIR}$PWD/${i}" "${i}"
     }
     mkdir -p "${ROOTDIR}$PWD/${i}" || :
   done
   mkdir -p "${ROOTDIR}${HOME}/.local/bin"
}

# "rustdesk" has a whole slew of dependencies on system-wide components that
# need to be installed in order to build from the sources. Install all of
# those into the simulated environment, unless they are already present from
# previous runs of this script.
runasroot apt update
runasroot apt install -y $(
  for p in ${DEBDEP}; do
    is_installed "${p}" "fakechroot fakeroot chroot ${ROOTDIR}" ||
      echo "${p}"
  done)

# Install a Rust development environment.
export CARGO_HOME="${PWD}/.cargo"
[ -x "${ROOTDIR}${CARGO_HOME}/bin/rustup" ] || {
  for i in 1 2; do
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs |
      runasuser sh -s -- -y && break || :
  done
}
[ -r "${ROOTDIR}${CARGO_HOME}/env" ] && source "${ROOTDIR}${CARGO_HOME}"/env || :
[ -x "${ROOTDIR}${CARGO_HOME}/bin/cargo-bundle" ] ||
  runasuser cargo install cargo-bundle

# If not already present, copy the sources from the host to the simulated
# environment.
if [ -d "${ROOTDIR}${PWD}/.git" ]; then
  cp -alf src "${ROOTDIR}${PWD}/"
else
  # runasuser git clone --no-checkout https://github.com/rustdesk/rustdesk tmp
  # runasuser mv tmp/.git .
  # runasuser rmdir tmp
  # runasuser git reset --hard HEAD
  for i in $(find . -maxdepth 1 \( -name ${ROOTDIR##*/} -o -print \)); do
    [ -e "${ROOTDIR}${PWD}/${i}" ] || cp -alf "${i}" "${ROOTDIR}${PWD}/"
  done
  rm -f "${ROOTDIR}${PWD}/appimage/"*.AppImage*
fi

# Install Microsoft's VCPKG unless it is already present.
export VCPKG_ROOT="${PWD}/vcpkg"
[ -e "${ROOTDIR}/${VCPKG_ROOT}/vcpkg" ] || {
  runasuser git clone https://github.com/microsoft/vcpkg vcpkg
  runasuser -d vcpkg git checkout 2023.04.15
}
[ -e "${ROOTDIR}/${VCPKG_ROOT}/vcpkg/installed" ] || {
  runasuser vcpkg/bootstrap-vcpkg.sh -disableMetrics
  runasuser vcpkg/vcpkg --vcpkg-root "${VCPKG_ROOT}" --x-install-root ${PWD}/vcpkg/installed install # libvpx libyuv opus aom
}

# Install the AppImage builder tools
[ -x "${ROOTDIR}${HOME}/.local/bin/appimage-builder" ] || {
  curl -Lo "${ROOTDIR}${HOME}/.local/bin/appimage-builder" \
       "https://github.com/AppImageCrafters/appimage-builder/releases/download/v1.1.0/appimage-builder-1.1.0-$(uname -i).AppImage"
  chmod +x "${ROOTDIR}${HOME}/.local/bin/appimage-builder"
}

# Download libsciter-gtk.so from the web.
[ -r "${ROOTDIR}${PWD}/libsciter-gtk.so" ] || {
  runasuser curl -Lo libsciter-gtk.so https://raw.githubusercontent.com/c-smile/sciter-sdk/master/bin.lnx/x64/libsciter-gtk.so
  mkdir -p "${ROOTDIR}${PWD}/target/"{debug,release}
  cp "${ROOTDIR}${PWD}/libsciter-gtk.so" "${ROOTDIR}${PWD}/target/debug/"
  cp "${ROOTDIR}${PWD}/libsciter-gtk.so" "${ROOTDIR}${PWD}/target/release/"
}

# The included "build.py" script has a few prerequisites that aren't met by
# default, when downloading the "rustdesk" sources from GitHub. This should
# be easy to fix.
runasuser rm -rf tmpdeb/DEBIAN
runasuser mkdir -p pam.d
[ -r "${ROOTDIR}${PWD}/pam.d/rustdesk.debian" ] ||
  runasuser cp /etc/pam.d/other pam.d/rustdesk.debian
runasuser ./build.py --hwcodec --flatpak --appimage # --flutter --unix-file-copy-paste
deb="$(ls "${ROOTDIR}${PWD}/rustdesk-"*.deb | tail -n 1)"
[ -r "${deb}" ] && cp -alf "${deb}" . || :
deb="${deb##*/}"

# Build the AppImage
PATH="${PATH//:/:${ROOTDIR}}:${PATH}" ./build_appimage.py
rm -f ${deb%.deb}.AppImage
cp -alf appimage/${deb%.deb}-*.AppImage .

# Build the FlatPak
./build_flatpak.sh
