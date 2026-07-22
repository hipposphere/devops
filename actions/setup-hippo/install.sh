#!/usr/bin/env bash
set -euo pipefail

version="${HIPPO_VERSION:-}"
base_url="${HIPPO_ARTIFACT_BASE_URL:-}"

if [[ -z "$version" ]]; then
  echo "::error::Set the setup-hippo 'version' input."
  exit 1
fi

case "${RUNNER_OS:-}" in
  Linux) os="linux" ;;
  macOS) os="macos" ;;
  Windows) os="windows" ;;
  *)
    echo "::error::Unsupported runner OS: ${RUNNER_OS:-unknown}"
    exit 1
    ;;
esac

case "${RUNNER_ARCH:-}" in
  X64) arch="x64" ;;
  ARM64) arch="arm64" ;;
  *)
    echo "::error::Unsupported runner architecture: ${RUNNER_ARCH:-unknown}"
    exit 1
    ;;
esac

binary_name="hippo"
extension="tar.gz"
if [[ "$os" == "windows" ]]; then
  binary_name="hippo.exe"
  extension="zip"
fi

archive="hippo-cli-$version-$os-$arch.$extension"
install_dir="$RUNNER_TEMP/hippo/$version/$os-$arch/bin"
download_dir="$RUNNER_TEMP/hippo/$version/$os-$arch/download"
extract_dir="$RUNNER_TEMP/hippo/$version/$os-$arch/package"

if [[ -x "$install_dir/$binary_name" ]]; then
  echo "Using cached $binary_name"
  echo "$install_dir" >> "$GITHUB_PATH"
  "$install_dir/$binary_name" self version >/dev/null
  exit 0
fi

mkdir -p "$install_dir" "$download_dir" "$extract_dir"

if [[ -n "$base_url" ]]; then
  url="${base_url%/}/$archive"
else
  url="https://github.com/hipposphere/native-artifacts/releases/download/hippo_cli-native-v$version/$archive"
fi
archive_path="$download_dir/$archive"

echo "Installing $archive"
curl -fsSL -o "$archive_path" "$url"

checksum_url="$url.sha256"
checksum_path="$archive_path.sha256"
if curl -fsSL -o "$checksum_path" "$checksum_url"; then
  if command -v shasum >/dev/null 2>&1; then
    (cd "$download_dir" && shasum -a 256 -c "$(basename "$checksum_path")")
  else
    echo "::warning::shasum is not available; skipped checksum verification."
  fi
else
  echo "::warning::Checksum not found for $archive; skipped checksum verification."
fi

rm -rf "$extract_dir"
mkdir -p "$extract_dir"

if [[ "$extension" == "zip" ]]; then
  unzip -q "$archive_path" -d "$extract_dir"
else
  tar -xzf "$archive_path" -C "$extract_dir"
fi

binary_path="$(find "$extract_dir" -type f -name "$binary_name" -perm -111 | head -n 1)"
if [[ -z "$binary_path" ]]; then
  binary_path="$(find "$extract_dir" -type f -name "$binary_name" | head -n 1)"
fi

if [[ -z "$binary_path" ]]; then
  echo "::error::Could not find $binary_name inside $archive."
  exit 1
fi

cp "$binary_path" "$install_dir/$binary_name"
chmod +x "$install_dir/$binary_name"

echo "$install_dir" >> "$GITHUB_PATH"
"$install_dir/$binary_name" self version >/dev/null
