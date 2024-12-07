TERMUX_PKG_HOMEPAGE=https://librewolf-community.gitlab.io/
TERMUX_PKG_DESCRIPTION="LibreWolf web browser - A privacy-focused fork of Firefox"
TERMUX_PKG_LICENSE="MPL-2.0"
TERMUX_PKG_MAINTAINER="@Mdmurtajim"
TERMUX_PKG_VERSION="133.0-1"
TERMUX_PKG_SRCURL=https://gitlab.com/api/v4/projects/32320088/packages/generic/librewolf-source/${TERMUX_PKG_VERSION}/librewolf-${TERMUX_PKG_VERSION}.source.tar.gz
TERMUX_PKG_SHA256=2090c835346ce395403007cb2d4982c12abc2e76df4bbc0083a60ae50a28c4d7
TERMUX_PKG_DEPENDS="ffmpeg, fontconfig, freetype, gdk-pixbuf, glib, gtk3, libandroid-shmem, libandroid-spawn, libc++, libcairo, libevent, libffi, libice, libicu, libjpeg-turbo, libnspr, libnss, libpixman, libsm, libvpx, libwebp, libx11, libxcb, libxcomposite, libxdamage, libxext, libxfixes, libxrandr, libxtst, pango, pulseaudio, zlib"
TERMUX_PKG_BUILD_DEPENDS="libcpufeatures, libice, libsm"
TERMUX_PKG_BUILD_IN_SRC=true
TERMUX_PKG_AUTO_UPDATE=true

termux_pkg_auto_update() {
    local e=0
    local api_url="https://gitlab.com/api/v4/projects/32320088/packages/generic/librewolf-source/latest/librewolf-latest.source.tar.gz"
    local api_url_r=$(curl -s "${api_url}")
    local latest_version=$(echo "${api_url_r}" | sed -nE "s/.*librewolf-(.*).source.tar.gz.*/\1/p")
    [[ -z "${api_url_r}" ]] && e=1
    [[ -z "${latest_version}" ]] && e=1

    local uptime_now=$(cat /proc/uptime)
    local uptime_s="${uptime_now//.*}"
    local uptime_h_limit=2
    local uptime_s_limit=$((uptime_h_limit*60*60))
    [[ -z "${uptime_s}" ]] && [[ "$(uname -o)" != "Android" ]] && e=1
    [[ "${uptime_s}" == 0 ]] && [[ "$(uname -o)" != "Android" ]] && e=1
    [[ "${uptime_s}" -gt "${uptime_s_limit}" ]] && e=1

    if [[ "${e}" != 0 ]]; then
        cat <<- EOL >&2
        WARN: Auto update failure!
        api_url_r=${api_url_r}
        latest_version=${latest_version}
        uptime_now=${uptime_now}
        uptime_s=${uptime_s}
        uptime_s_limit=${uptime_s_limit}
        EOL
        return
    fi

    termux_pkg_upgrade_version "${latest_version}"
}

termux_step_post_get_source() {
    local f="media/ffvpx/config_unix_aarch64.h"
    echo "Applying sed substitution to ${f}"
    sed -E '/^#define (CONFIG_LINUX_PERF|HAVE_SYSCTL) /s/1$/0/' -i ${f}
}

termux_step_pre_configure() {
    termux_setup_flang
    local __fc_dir="$(dirname $(command -v $FC))"
    local __flang_toolchain_folder="$(realpath "$__fc_dir"/..)"
    if [ ! -d "$TERMUX_PKG_TMPDIR/librewolf-toolchain" ]; then
        rm -rf "$TERMUX_PKG_TMPDIR"/librewolf-toolchain-tmp
        mv "$__flang_toolchain_folder" "$TERMUX_PKG_TMPDIR"/librewolf-toolchain-tmp

        cp "$(command -v "$CC")" "$TERMUX_PKG_TMPDIR"/librewolf-toolchain-tmp/bin/
        cp "$(command -v "$CXX")" "$TERMUX_PKG_TMPDIR"/librewolf-toolchain-tmp/bin/
        cp "$(command -v "$CPP")" "$TERMUX_PKG_TMPDIR"/librewolf-toolchain-tmp/bin/

        mv "$TERMUX_PKG_TMPDIR"/librewolf-toolchain-tmp "$TERMUX_PKG_TMPDIR"/librewolf-toolchain
    fi
    export PATH="$TERMUX_PKG_TMPDIR/librewolf-toolchain/bin:$PATH"

    termux_setup_nodejs
    termux_setup_rust

    if [ "$TERMUX_DEBUG_BUILD" = false ]; then
        case "${TERMUX_ARCH}" in
        aarch64|arm|i686|x86_64) RUSTFLAGS+=" -C debuginfo=1" ;;
        esac
    fi

    cargo install cbindgen

    export HOST_CC=$(command -v clang)
    export HOST_CXX=$(command -v clang++)

    export BINDGEN_CFLAGS="--target=$CCTERMUX_HOST_PLATFORM --sysroot=$TERMUX_PKG_TMPDIR/librewolf-toolchain/sysroot"
    local env_name=BINDGEN_EXTRA_CLANG_ARGS_${CARGO_TARGET_NAME@U}
    env_name=${env_name//-/_}
    export $env_name="$BINDGEN_CFLAGS"

    CXXFLAGS+=" -U__ANDROID__ -D_LIBCPP_HAS_NO_C11_ALIGNED_ALLOC"
    LDFLAGS+=" -landroid-shmem -landroid-spawn -llog"

    if [ "$TERMUX_ARCH" = "arm" ]; then
        LDFLAGS+=" -l:libndk_compat.a"
    fi
}

termux_step_configure() {
    if [ "$TERMUX_CONTINUE_BUILD" == "true" ]; then
        termux_step_pre_configure
        cd $TERMUX_PKG_SRCDIR
    fi

    sed \
        -e "s|@TERMUX_HOST_PLATFORM@|${TERMUX_HOST_PLATFORM}|" \
        -e "s|@TERMUX_PREFIX@|${TERMUX_PREFIX}|" \
        -e "s|@CARGO_TARGET_NAME@|${CARGO_TARGET_NAME}|" \
        $TERMUX_PKG_BUILDER_DIR/mozconfig.cfg > .mozconfig

    if [ "$TERMUX_DEBUG_BUILD" = true ]; then
        cat >>.mozconfig - <<END
ac_add_options --enable-debug-symbols
ac_add_options --disable-install-strip
END
    fi

    ./mach configure
}

termux_step_make() {
    ./mach build
    ./mach buildsymbols
}

termux_step_make_install() {
    ./mach install

    install -Dm644 -t "${TERMUX_PREFIX}/share/applications" "${TERMUX_PKG_BUILDER_DIR}/librewolf.desktop"
}

termux_step_post_make_install() {
    local r=$("${READELF}" -d "${TERMUX_PREFIX}/bin/librewolf")
    if [[ -n "$(echo "${r}" | grep "(RELR)")" ]]; then
        termux_error_exit "DT_RELR is unsupported on Android 8.x and older\n${r}"
    fi
}
