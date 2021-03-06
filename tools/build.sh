#!/usr/bin/env bash
set -e

have_cmd()
{
    command -v "$1" >/dev/null 2>&1
}

export NUM_JOBS=4
if [ -f /proc/cpuinfo ]; then
    export NUM_JOBS=$(cat /proc/cpuinfo | grep ^processor | wc -l)
fi

ANALYZE=false
LIBTYPE="shared"
MESON_OPTIONS=""
NINJA_TARGET=""
EXTRA_CXXFLAGS=""
COMPILER_VERSION=""
BUILD=""
BUILDTYPE="release"
NDK_ARCH=""

GETOPT='getopt'
if [ -z "$ANDROID_NDK" ]; then
    if have_cmd ndk-build; then
        export ANDROID_NDK=$(dirname $(command -v ndk-build))
    fi
fi
export NDK_TOOLSDIR="$ANDROID_NDK/toolchains/llvm/prebuilt/linux-x86_64"
if [ "$(uname)" == "Darwin" ]; then
    GETOPT='/usr/local/opt/gnu-getopt/bin/getopt'
    export NDK_TOOLSDIR="$ANDROID_NDK/toolchains/llvm/prebuilt/darwin-x86_64"
elif [ "$(uname)" == "FreeBSD" ]; then
    GETOPT='/usr/local/bin/getopt'
fi

if have_cmd gtar; then
    TAR=$(command -v gtar)
elif have_cmd tar; then
    TAR=$(command -v tar)
else
    echo "Could not find tar or gtar. Please install tar and try again."
    exit 1
fi

if (($# < 1)); then
    echo "Usage: build.sh [args] --compiler/platform. Please see README.md for examples."
    exit 0
fi

TEMPOPT=`"$GETOPT" -n "build.sh" -o x,b: -l analyze,clang,gcc,mingw-w64,prefix:,install:,sanitizer:,compiler-version:,ndk:,iphone:,iphonesim:,buildtype:,lto:,clang-tidy-version:,unity:,python-version: -- "$@"`
eval set -- "$TEMPOPT"
while true; do
    case "$1" in
        -x | --analyze ) ANALYZE=true; shift ;;
        -b | --buildtype ) BUILDTYPE=$2; shift 2 ;;
        --install ) MESON_OPTIONS="$MESON_OPTIONS --prefix=$2"; NINJA_TARGET="install"; shift 2 ;;
        --sanitizer ) MESON_OPTIONS="$MESON_OPTIONS -Db_sanitize=$2"; shift 2 ;;
        --clang | --gcc | --mingw-w64 ) BUILD="$1"; shift ;;
        --iphone | --iphonesim ) BUILD="$1"; LIBTYPE="$2"; shift 2 ;;
        --ndk ) BUILD="$1"; NDK_ARCH="$2"; shift 2 ;;
        --compiler-version) COMPILER_VERSION="-$2"; shift 2 ;;
        --lto) MESON_OPTIONS="$MESON_OPTIONS -Dlto=$2"; shift 2 ;;
        --clang-tidy-version) MESON_OPTIONS="$MESON_OPTIONS -Dclang-tidy-version=-$2"; NINJA_TARGET="src/clang-tidy"; shift 2 ;;
        --prefix) MESON_OPTIONS="$MESON_OPTIONS --prefix=$2"; shift 2 ;;
        --unity) MESON_OPTIONS="$MESON_OPTIONS --unity=$2"; shift 2 ;;
        --python-version) MESON_OPTIONS="$MESON_OPTIONS -Dpython-version=$2"; shift 2 ;;
        -- ) shift; break ;;
        *) break ;;
    esac
done

if have_cmd ninja-build; then
    NINJA=$(command -v ninja-build)
elif have_cmd ninja; then
    NINJA=$(command -v ninja)
else
    echo "Could not find ninja-build or ninja. Please install ninja and try again."
    exit 1
fi

export CFLAGS="$CFLAGS"
export CPPFLAGS="$CFLAGS"
export PATH_BASE=$PATH
export BUILDTYPE

MESON_OPTIONS="${MESON_OPTIONS} --buildtype=${BUILDTYPE}"

if [ \( "$BUILDTYPE" = "release" \) ]; then
    if ! ([ "$BUILD" = "--iphone" ] || [ "$BUILD" = "--iphonesim" ] || ([[ $MESON_OPTIONS =~ "Dpython-version" ]] && [ "$(uname)" = "Darwin" ])); then
        MESON_OPTIONS="${MESON_OPTIONS} --strip"
    fi
fi

function compress_patch() {
    meson_files=($(find subprojects -mindepth 2 -maxdepth 2 -not -wholename '*packagecache*' -wholename '*-meson/meson.build*' | sort))
    directories=($(find subprojects -mindepth 1 -maxdepth 1 -name '*wrap*' | xargs grep directory | cut -d ' ' -f 3 | grep -v json | sort))
    patch_names=($(find subprojects -mindepth 1 -maxdepth 1 -name '*wrap*' | xargs grep patch_filename | cut -d ' ' -f 3 | sort))

    for i in ${!directories[@]}; do
        tmpdir=$(mktemp -d)
        mkdir -p ${tmpdir}/${directories[$i]}
        cp ${meson_files[$i]} ${tmpdir}/${directories[$i]}
        pwd=$PWD
        pushd . > /dev/null
        cd ${tmpdir}
        $TAR --mode=go=rX,u+rw,a-s --sort=name --owner=0 --group=0 --numeric-owner --mtime="2018-08-01 00:00Z" -cf ${pwd}/$(dirname ${meson_files[$i]})/${patch_names[$i]} ${directories[$i]}
        popd > /dev/null
        rm -rf ${tmpdir}
    done
}

function build() {
    CXX_COMPILER="$2$COMPILER_VERSION"
    C_COMPILER="$1$COMPILER_VERSION"
    export CXX="$CXX_COMPILER"
    export CCC_CXX="$CXX_COMPILER"
    export CC="$C_COMPILER"
    export CCC_CC="$C_COMPILER"
    export CC="$C_COMPILER"

    SCAN_BUILD=""
    if [ $ANALYZE == true ] ; then
        SCAN_BUILD="scan-build$COMPILER_VERSION --use-cc=$C_COMPILER --use-c++=$CXX_COMPILER"
    fi

    if [ ! -f "build-$C_COMPILER/build.ninja" ]; then
        rm -rf build-$C_COMPILER/meson-private
        compress_patch
        CXXFLAGS=$EXTRA_CXXFLAGS $SCAN_BUILD meson build-$C_COMPILER --default-library=${LIBTYPE} --werror ${MESON_OPTIONS}
    fi

    $NINJA -C build-$C_COMPILER -j$NUM_JOBS $NINJA_TARGET
}

function set_cross_build_env() {
    bld_root="$PWD/build-clang-$1-$2"
    export HOST_ARCH=$2
    case $2 in
        armeabi-v7a)
            export SDK_ARCH=arm
            export SDK_CPU=armv7
            export SDK_CFLAGS="-march=armv7-a -mfloat-abi=softfp -mfpu=neon -mthumb"
            export SDK_LDFLAGS="-Wl,--fix-cortex-a8"
            ;;
        arm64-v8a)
            export SDK_ARCH=aarch64
            export SDK_CPU=arm64-v8a
            export SDK_CFLAGS="-march=armv8-a -flax-vector-conversions"
            ;;
        iphone)
            export SDK_ARCH=aarch64
            export SDK_CPU=arm64
            export SDK_CFLAGS="-miphoneos-version-min=9"
            ;;
        iphonesim)
            export SDK_ARCH=x86_64
            export SDK_CPU=x86_64
            export SDK_CFLAGS="-miphoneos-version-min=9"
            ;;
        x86_64)
            export SDK_ARCH=$HOST_ARCH
            export SDK_CPU=$HOST_ARCH
            ;;
        *)
            export SDK_ARCH=$2
            export SDK_CPU=i686
            ;;
    esac
}

if [ \( "$(uname)" != "Darwin" \) -a \( "$BUILD" = "--gcc" \) ]; then
    build gcc g++
fi

if [ \( "$BUILD" = "--clang" \) ]; then
    build clang clang++
fi


if [ \( -d "$ANDROID_NDK" \) -a \( "$BUILD" = "--ndk" \) ]; then

    echo ${ANDROID_NDK:?}
    function build() {
        bld_root="$PWD/build-clang-$1-$2"

        export SDK_CFLAGS="$SDK_CFLAGS -DPIC -fPIC"
        export SDK_CPPFLAGS="$SDK_CFLAGS"
        export SDK_LDFLAGS="$SDK_LDFLAGS -static-libstdc++"

        if [[ $SDK_ARCH == *"64"* ]]; then
            export ANDROID_VERSION="21"
        else
            export ANDROID_VERSION="19"
        fi

        export PATH=$NDK_TOOLSDIR/bin:$PATH_BASE
        mkdir -p build-clang-$1-$2

        if [ ! -f "build-clang-$1-$2/build.ninja" ]; then
            rm -rf build-clang-$1-$2/meson-private
            export archfilename=$SDK_ARCH
            export clangarchname=$HOST_ARCH
            case $archfilename in
                armeabi-v7a) archfilename=arm;;
                arm64-v8a) archfilename=aarch64;;
                x86) archfilename=i686;;
            esac
            case $clangarchname in
                armeabi-v7a) clangarchname=armv7a;;
                arm64-v8a) clangarchname=aarch64;;
                x86) clangarchname=i686;;
            esac
            export SDK_PLATFORM=$(basename $NDK_TOOLSDIR/bin/$archfilename-linux-android*-strip | sed 's/-strip$//')
            export AR="$NDK_TOOLSDIR/bin/$SDK_PLATFORM-ar"
            export RANLIB="$NDK_TOOLSDIR/bin/$SDK_PLATFORM-ranlib"

            ./tools/make_txt.sh $bld_root $bld_root/$1_$2_ndk.txt $1 ndk $2
            compress_patch
            meson $bld_root --cross-file $bld_root/$1_$2_ndk.txt --default-library=${LIBTYPE} ${MESON_OPTIONS}
        fi
        $NINJA -C $bld_root -j$NUM_JOBS -v $NINJA_TARGET
    }

    if [ -n "$NDK_ARCH" ]; then
        all_archs="$NDK_ARCH"
    else
        all_archs="armeabi-v7a arm64-v8a x86 x86_64"
    fi
    for a in $all_archs; do
        set_cross_build_env android $a
        build android $a
    done
fi

if [ \( "$BUILD" = "--iphone" \) -o \( "$BUILD" = "--iphonesim" \) ]; then

    function build() {
        bld_root="$PWD/build-clang-$1-$2"

        . tools/ios_env.sh $BUILD

        export PATH=$XCODE_DEFAULT_PATH:$XCODE_IOS_PATH:$PATH_BASE
        export AR=ar

        if [ ! -f "build-clang-$1-$2/build.ninja" ]; then
            rm -rf build-clang-$1-$2/meson-private
            mkdir -p build-clang-$1-$2
            ./tools/make_txt.sh $bld_root $bld_root/$1_$2_ios.txt $2 $2
            compress_patch
            meson $bld_root --cross-file $bld_root/$1_$2_ios.txt --default-library=${LIBTYPE} ${MESON_OPTIONS}
        fi
        $NINJA -C $bld_root -j$NUM_JOBS -v $NINJA_TARGET
    }

    if test "$BUILD" == "--iphone"; then
        PLATFORM=iphone
    else
        PLATFORM=iphonesim
    fi
    set_cross_build_env ios $PLATFORM
    build ios $PLATFORM
fi

if [ \( "$BUILD" = "--mingw-w64" \) ]; then

    function build() {
        bld_root="$PWD/build-$1-$2"

        export SDK_CFLAGS_NO_ARCH="$SDK_CFLAGS"
        export SDK_CFLAGS="$SDK_CFLAGS $ARCHS"
        export SDK_CPPFLAGS="$SDK_CFLAGS"
        export SDK_LDFLAGS="$SDK_CFLAGS"
        export AR="x86_64-w64-mingw32-gcc-ar"
        export RANLIB="x86_64-w64-mingw32-ranlib"
        if [ ! -f "build-$1-$2/build.ninja" ]; then
            rm -rf build-$1-$2/meson-private
            mkdir -p $bld_root
            ./tools/make_txt.sh $bld_root $bld_root/$1.txt $1 $1
            compress_patch
            meson $bld_root --cross-file $bld_root/$1.txt --default-library=${LIBTYPE} ${MESON_OPTIONS}
        fi
        $NINJA -C $bld_root -j$NUM_JOBS -v $NINJA_TARGET
    }

    set_cross_build_env windows mingw-w64
    build windows mingw-w64
fi
