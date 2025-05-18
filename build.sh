#!/bin/bash
set -e # Exit on error

TAG="beta"
INSTALL=false                                  # Default: No installation
HASH_FILE=".dynv_hash"                         # File to store last build hash
NDK_PATH="$HOME/Android/Sdk/ndk/29.0.13113456" # Path to NDK

# Root Check Function
check_root() {
	local message="$1"

	if su -c "echo" >/dev/null 2>&1; then
		return 1 # Not root
	elif [ "$EUID" -ne 0 ]; then
		echo "$message"
		exit 1
	fi
}

# Validate Arguments
validate_args() {
	for arg in "$@"; do
		if [[ ! "$arg" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
			echo "> Error: Arguments must be numeric"
			exit 1
		fi
	done
}

# Read version from module.prop
read_version_info() {
	grep -Eo 'version=v[0-9.]+' module.prop | cut -d'=' -f2 | sed 's/v//'
}

# Read versionCode from module.prop
read_version_code() {
	grep -Eo 'versionCode=[0-9]+' module.prop | cut -d'=' -f2
}

# Update JSON configuration
update_json() {
	local file="$1"
	local versionCode="${2:-$versionCode}"
	local version="${3:-$version}"
	local zipUrl="${4:-https://github.com/lululoid/LMKD-PSI-Activator/releases/download/v${version}_$versionCode/fmiop-v${version}_${versionCode}-$TAG.zip}"
	local changelog="${5:-https://github.com/lululoid/LMKD-PSI-Activator/releases/download/v${version}_${versionCode}/fmiop-v${version}_${versionCode}-changelog.md}"

	temp_file=$(mktemp)
	jq --arg code "$versionCode" \
		--arg ver "$version" \
		--arg zip "$zipUrl" \
		--arg log "$changelog" \
		'.versionCode = $code | .version = $ver | .zipUrl = $zip | .changelog = $log' "$file" >"$temp_file" && mv "$temp_file" "$file"
}

# Check if dynv.cpp has changed
should_rebuild_dynv() {
	new_hash=$(sha256sum dynv.cpp 2>/dev/null | awk '{print $1}')

	if [[ -f "$HASH_FILE" ]]; then
		local old_hash
		old_hash=$(cat "$HASH_FILE")

		if [[ "$new_hash" == "$old_hash" ]]; then
			echo "- No changes detected in dynv.cpp, skipping rebuild."
			return 1 # No rebuild needed
		else
			echo "$new_hash" >"$HASH_FILE"
			echo "- dynv.cpp changed, rebuilding..."
		fi
	fi

	return 0 # Rebuild needed
}

# Generate Changelog from Git and remove old ones
generate_changelog() {
	local version="$1"
	local versionCode="$2"
	local changelog_file="fmiop-v${version}_${versionCode}-changelog.md"
	local message="
📣 For more updates and discussions about bugs, features, etc.,
join our ⌯⌲ Telegram channel: [**Initechzer0**](https://t.me/initentangtech)
or our ⌯⌲ Telegram group: [**Initechzer0 Chat**](https://t.me/+ff5HBVsV8gsxODk1)."

	# Remove previous changelogs
	rm -f fmiop-v*-changelog.md
	echo "- Removed old changelogs"

	echo "# Changelog for v${version} (Build ${versionCode})" >"$changelog_file"
	echo "$message" >>"$changelog_file"
	echo "" >>"$changelog_file"

	# Include only local commits not pushed to remote
	local local_commits
	local_commits=$(git log @{u}..HEAD --pretty=format:"- %s (%h)" 2>/dev/null)

	if [[ -n "$local_commits" ]]; then
		echo "$local_commits" >>"$changelog_file"
	else
		echo "- No local changes to include in changelog" >>"$changelog_file"
	fi

	echo "" >>"$changelog_file"
	echo "- Auto-generated from local Git commits" >>"$changelog_file"

	echo "- Changelog generated: $changelog_file"
}

build_yaml-cpp() {
	local abis pwd
	abis=("arm64-v8a" "armeabi-v7a")
	pwd=$(pwd)

	cd yaml-cpp || exit
	mkdir build 2>/dev/null || :
	cd build || exit

	for ABI in "${abis[@]}"; do
		BUILD_DIR="build-android-$ABI"
		if [ ! -d "$BUILD_DIR" ]; then
			echo "- Building yaml-cpp for $ABI"
			cmake -S . -B "$BUILD_DIR" \
				-DCMAKE_TOOLCHAIN_FILE="$NDK_PATH/build/cmake/android.toolchain.cmake" \
				-DANDROID_ABI="$ABI" \
				-DANDROID_PLATFORM=android-21 \
				-DCMAKE_BUILD_TYPE=Release \
				-DYAML_BUILD_SHARED_LIBS=OFF ..
			cd "$BUILD_DIR"
			make
			cd ..
		else
			echo "- yaml-cpp for $ABI already built"
		fi
	done
	cd "$pwd"
}

build_dynv() {
	CPATH=$NDK_PATH/toolchains/llvm/prebuilt/linux-x86_64/bin
	echo "- Building dynamic virtual memory..."

	if ! (
		for ABI in arm64-v8a armeabi-v7a; do
			echo "- Building dynv for $ABI"
			if [ "$ABI" == "arm64-v8a" ]; then
				"$CPATH"/aarch64-linux-android21-clang++ -o system/bin/dynv-$ABI dynv.cpp -std=c++17 -pthread \
					-I./yaml-cpp/include \
					-L./yaml-cpp/build/build-android-$ABI \
					-lyaml-cpp \
					-static-libgcc -static-libstdc++ -llog || return 1
			elif [ "$ABI" == "armeabi-v7a" ]; then
				"$CPATH"/armv7a-linux-androideabi21-clang++ -o system/bin/dynv-$ABI dynv.cpp -std=c++17 -pthread \
					-I./yaml-cpp/include \
					-L./yaml-cpp/build/build-android-$ABI \
					-lyaml-cpp \
					-static-libgcc -static-libstdc++ -llog || return 1
			fi
		done
	); then
		echo "- Error: Failed to build dynv binaries."
		exit 1
	else
		echo "- dynv binaries built successfully."
	fi
}

# Parse arguments
while getopts ":i" opt; do
	case "$opt" in
	i) INSTALL=true ;; # Enable installation
	*)
		echo "Usage: $0 [-i] <version> <versionCode>"
		exit 1
		;;
	esac
done
shift $((OPTIND - 1))

# Main Execution
main() {
	local version="${1:-$(read_version_info)}"
	local versionCode="${2:-$(($(read_version_code) + 1))}"

	validate_args "$version" "$versionCode"

	# Check if dynv.cpp changed before rebuilding
	if should_rebuild_dynv; then
		build_yaml-cpp
		build_dynv
	else
		echo "- dynv.cpp unchanged, skipping rebuild."
	fi

	# Update module.prop
	sed -i -E "s/^version=v[0-9.]+/version=v$version/; s/^versionCode=[0-9]+/versionCode=$versionCode/" module.prop

	local module_name
	module_name=$(grep -Eo '^id=.*' module.prop | cut -d'=' -f2)

	update_json update_config.json "$versionCode" "$version"

	# Generate Changelog
	generate_changelog "$version" "$versionCode"

	local package_name="packages/${module_name}-v${version}_${versionCode}-$TAG.zip"

	# 🧹 Delete old packages for this module
	echo "- Cleaning up old packages..."
	find packages/ -type f -name "${module_name}-v*.zip" ! -name "$(basename "$package_name")" -delete

	echo "- Creating zip package: $package_name"
	7za a -mx=9 -bd -y "$package_name" \
		META-INF fmiop.sh customize.sh module.prop "*service.sh" \
		uninstall.sh action.sh config.yaml \
		system/bin tools >/dev/null 2>&1

	if $INSTALL; then
		check_root "You need ROOT to install this module" || su -c "magisk --install-module $package_name"
	else
		echo "- Skipping installation. Package built at: $package_name"
	fi
	
	adb push "$package_name" /sdcard/Download
}

# Run the script
main "$@"