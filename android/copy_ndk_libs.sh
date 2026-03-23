#!/bin/bash
# Script to copy libc++_shared.so from Android NDK to jniLibs

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL_PROPERTIES="$SCRIPT_DIR/local.properties"

read_local_property() {
    local key="$1"
    if [ -f "$LOCAL_PROPERTIES" ]; then
        grep -E "^${key}=" "$LOCAL_PROPERTIES" | sed -E "s/^${key}=//" | tail -n 1
    fi
}

if [ -z "$ANDROID_HOME" ]; then
    ANDROID_HOME="$ANDROID_SDK_ROOT"
fi

if [ -z "$ANDROID_HOME" ]; then
    ANDROID_HOME="$(read_local_property "sdk.dir")"
fi

if [ -n "$ANDROID_HOME" ]; then
    ANDROID_HOME="${ANDROID_HOME//\\//}"
fi

if [ -z "$ANDROID_NDK_HOME" ]; then
    ANDROID_NDK_HOME="$(read_local_property "ndk.dir")"
fi

if [ -n "$ANDROID_NDK_HOME" ]; then
    ANDROID_NDK_HOME="${ANDROID_NDK_HOME//\\//}"
fi

# Get NDK path from environment or use default
if [ -z "$ANDROID_NDK_HOME" ]; then
    if [ -z "$ANDROID_HOME" ]; then
        echo "Error: ANDROID_HOME or ANDROID_NDK_HOME must be set"
        exit 1
    fi
    # Try to find NDK in Android SDK
    NDK_DIR="$ANDROID_HOME/ndk"
    if [ ! -d "$NDK_DIR" ]; then
        echo "Error: NDK not found in $NDK_DIR"
        exit 1
    fi
    # Use the latest NDK version
    ANDROID_NDK_HOME=$(ls -d "$NDK_DIR"/* | sort -V | tail -n 1)
fi

echo "Using NDK: $ANDROID_NDK_HOME"

# Target directory
JNI_LIBS_DIR="$(dirname "$0")/app/src/main/jniLibs"

PREBUILT_DIRS=(
    "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64"
    "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/windows-x86_64"
)

# Map ABIs to NDK architecture names
declare -A ABI_MAP
ABI_MAP["arm64-v8a"]="aarch64-linux-android"
ABI_MAP["armeabi-v7a"]="arm-linux-androideabi"
ABI_MAP["x86_64"]="x86_64-linux-android"
ABI_MAP["x86"]="i686-linux-android"

# Create directories for each ABI
for ABI in arm64-v8a armeabi-v7a x86_64 x86; do
    mkdir -p "$JNI_LIBS_DIR/$ABI"
    
    ARCH="${ABI_MAP[$ABI]}"

    NDK_PATHS=()
    for PREBUILT in "${PREBUILT_DIRS[@]}"; do
        NDK_PATHS+=("$PREBUILT/sysroot/usr/lib/$ARCH/libc++_shared.so")
        NDK_PATHS+=("$PREBUILT/sysroot/usr/lib/$ABI/libc++_shared.so")
    done
    
    # Legacy NDK location
    NDK_PATHS+=("$ANDROID_NDK_HOME/sources/cxx-stl/llvm-libc++/libs/$ABI/libc++_shared.so")
    
    FOUND=false
    for NDK_LIB in "${NDK_PATHS[@]}"; do
        if [ -f "$NDK_LIB" ]; then
            cp "$NDK_LIB" "$JNI_LIBS_DIR/$ABI/"
            echo "Copied libc++_shared.so for $ABI from $NDK_LIB"
            FOUND=true
            break
        fi
    done
    
    if [ "$FOUND" = false ]; then
        echo "Warning: libc++_shared.so not found for $ABI"
    fi
done

echo "Done! libc++_shared.so copied to jniLibs"
