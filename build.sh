#!/bin/bash
TAG=beta

check_root() {
	local message="$1"

	if su -c "echo"; then
		false
	elif [ "$EUID" -ne 0 ]; then
		echo "$message"
		exit 1
	fi
}

version=$1
versionCode=$2

# Check for decimal in arguments
for arg in "$@"; do
	if [[ $arg =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
		true
	else
		echo "> Arguments must be number"
		exit 1
	fi
done

# Extract version information from module.prop
last_version=$(grep -o 'version=v[0-9.]*' module.prop |
	cut -d'=' -f2 | sed 's/v//')

if [ -z "$version" ]; then
	version=$(grep -o 'version=v[0-9.]*' module.prop |
		cut -d'=' -f2 | sed 's/v//')
fi

if [ -z "$versionCode" ]; then
	versionCode=$(grep versionCode module.prop | cut -d '=' -f2)
	versionCode=$((versionCode + 1))
fi

# Update module.prop with the new version and versionCode
sed -i "s/\(^version=v\)[0-9.]*\(.*\)/\1$version\2/; s/\(^versionCode=\)[0-9]*/\1$versionCode/" module.prop

# Extract module name
module_name=$(sed -n 's/^id=\(.*\)/\1/p' module.prop)
fogimp_pkg=$(ls -tr packages/fogimp* | tail -n1)

update_json() {
	local file="$1"
	local versionCode="${2:-$versionCode}"
	local version="${3:-$version}"
	local zipUrl="${4:-https://github.com/lululoid/LMKD-PSI-Activator/releases/download/v${version}/fmiop-v${version}_${versionCode}-$TAG.zip}"
	local changelog="${5:-https://github.com/lululoid/LMKD-PSI-Activator/releases/download/v${version}/fmiop-v${version}_${versionCode}-changelog.md}"

	jq --arg code "$versionCode" \
		--arg ver "$version" \
		--arg zip "$zipUrl" \
		--arg log "$changelog" \
		'.versionCode = $code | .version = $ver | .zipUrl = $zip | .changelog = $log' "$file" | sponge "$file"
}

update_json update_config.json "$versionCode" "$version"

echo "- Building dynamic virtual memory"
g++ -o system/bin/dynv dynv.cpp -std=c++17 -pthread -lyaml-cpp -static-libgcc -static-libstdc++ -L"$PREFIX"/aarch64-linux-android/lib -llog
# Create a zip package
package_name="packages/$module_name-v${version}_$versionCode-$TAG.zip"
7za a "$package_name" \
	META-INF \
	fmiop.sh \
	customize.sh \
	module.prop \
	cleaner.zip \
	./*service.sh \
	vars.sh \
	action.sh \
	sed \
	yq tar \
	config.yaml \
	system/bin \
	$fogimp_pkg

# check_root "You need ROOT to install this module" || su -c "magisk --install-module $package_name"
