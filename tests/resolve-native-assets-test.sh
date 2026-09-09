#!/usr/bin/env bash

set -euo pipefail

devops_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

mkdir -p "$fixture/repo/packages/example_native/rust/src" "$fixture/bin"

cat > "$fixture/repo/packages/example_native/rust/Cargo.toml" <<'EOF'
[package]
name = "example_native"
version = "1.2.3"
edition = "2024"
EOF

cat > "$fixture/repo/packages/example_native/rust/rust-toolchain.toml" <<'EOF'
[toolchain]
channel = "1.95.0"
EOF

cat > "$fixture/repo/packages/example_native/rust/src/lib.rs" <<'EOF'
pub fn value() -> i32 { 1 }
EOF

cat > "$fixture/repo/native-assets.json" <<'EOF'
{
  "version": 1,
  "packages": {
    "example_native": {
      "crate": "packages/example_native/rust/Cargo.toml",
      "native_inputs": ["packages/example_native/rust"]
    }
  }
}
EOF

cat > "$fixture/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "${FAKE_RELEASE_EXISTS:-false}" == "true" ]]; then
  if [[ "$*" == *"--json assets,body"* ]]; then
    printf '%s\n' '{"assets":[],"body":""}'
  fi
  exit 0
fi
exit 1
EOF
chmod +x "$fixture/bin/gh"

(
  cd "$fixture/repo"
  git init -q
  git config user.name test
  git config user.email test@example.com
  git add .
  git commit -qm initial

  output="$fixture/output"
  : > "$output"
  PATH="$fixture/bin:$PATH" \
    GITHUB_REPOSITORY=hippolabs-org/example \
    GITHUB_REPOSITORY_OWNER=hippolabs-org \
    GITHUB_OUTPUT="$output" \
    NATIVE_CONFIG_PATH=native-assets.json \
    NATIVE_DRY_RUN=true \
    bash "$devops_root/actions/resolve-native-assets/resolve.sh"

  targets="$(sed -n 's/^targets=//p' "$output")"
  [[ "$(jq 'length' <<< "$targets")" == "3" ]]
  [[ "$(jq -r '.[0].package' <<< "$targets")" == "example_native" ]]
  [[ "$(jq -r '.[0].release_owner' <<< "$targets")" == "hippolabs-org" ]]
  [[ "$(jq -r '.[0].release_repository' <<< "$targets")" == "example" ]]
  [[ "$(sed -n 's/^missing_count=//p' "$output")" == "3" ]]

  jq '.packages.example_native.targets = [
    "android-arm", "android-arm64", "android-x64",
    "ios-device-arm64", "ios-simulator-arm64", "ios-simulator-x64",
    "linux-x64", "linux-arm64", "macos-arm64", "macos-x64",
    "windows-arm64", "windows-x64"
  ]' native-assets.json > native-assets.all-platforms.json
  : > "$output"
  PATH="$fixture/bin:$PATH" \
    GITHUB_REPOSITORY=hippolabs-org/example \
    GITHUB_REPOSITORY_OWNER=hippolabs-org \
    GITHUB_OUTPUT="$output" \
    NATIVE_CONFIG_PATH=native-assets.all-platforms.json \
    NATIVE_DRY_RUN=true \
    bash "$devops_root/actions/resolve-native-assets/resolve.sh"
  targets="$(sed -n 's/^targets=//p' "$output")"
  [[ "$(jq 'length' <<< "$targets")" == "12" ]]
  [[ "$(jq -r '.[] | select(.triple == "aarch64-apple-ios") | .artifact' <<< "$targets")" == \
    "example_native-1.2.3-ios-device-arm64-libexample_native.dylib" ]]
  [[ "$(jq -r '.[] | select(.triple == "aarch64-linux-android") | .source' <<< "$targets")" == \
    ".dart_tool/native-assets/example_native/aarch64-linux-android/release/libexample_native.so" ]]
  [[ "$(jq -r '.[] | select(.triple == "x86_64-pc-windows-msvc") | .runner' <<< "$targets")" == \
    "windows-2025" ]]
  [[ "$(jq -r '.[] | select(.triple == "aarch64-pc-windows-msvc") | .library' <<< "$targets")" == \
    "example_native.dll" ]]

  jq '.packages.example_native.release_repository = "native-artifacts"' \
    native-assets.json > native-assets.central.json
  : > "$output"
  PATH="$fixture/bin:$PATH" \
    GITHUB_REPOSITORY=hippolabs-org/example \
    GITHUB_REPOSITORY_OWNER=hippolabs-org \
    GITHUB_OUTPUT="$output" \
    NATIVE_CONFIG_PATH=native-assets.central.json \
    NATIVE_DRY_RUN=true \
    bash "$devops_root/actions/resolve-native-assets/resolve.sh"
  targets="$(sed -n 's/^targets=//p' "$output")"
  [[ "$(jq -r '.[0].release_owner' <<< "$targets")" == "hippolabs-org" ]]
  [[ "$(jq -r '.[0].release_repository' <<< "$targets")" == "native-artifacts" ]]

  : > "$output"
  PATH="$fixture/bin:$PATH" \
    GITHUB_REPOSITORY=hippolabs-org/example \
    GITHUB_REPOSITORY_OWNER=hippolabs-org \
    GITHUB_OUTPUT="$output" \
    NATIVE_CONFIG_PATH=native-assets.json \
    NATIVE_PACKAGE_SCOPE=another_package \
    NATIVE_DRY_RUN=true \
    bash "$devops_root/actions/resolve-native-assets/resolve.sh"
  [[ "$(sed -n 's/^targets=//p' "$output")" == "[]" ]]

  git tag example_native-native-v1.2.3
  printf '\npub fn changed() {}\n' >> packages/example_native/rust/src/lib.rs
  git add .
  git commit -qm changed

  if failure_output="$(
    PATH="$fixture/bin:$PATH" \
      FAKE_RELEASE_EXISTS=true \
      GITHUB_REPOSITORY=hippolabs-org/example \
      GITHUB_REPOSITORY_OWNER=hippolabs-org \
      GITHUB_OUTPUT="$output" \
      NATIVE_CONFIG_PATH=native-assets.json \
      NATIVE_DRY_RUN=true \
      bash "$devops_root/actions/resolve-native-assets/resolve.sh" 2>&1
  )"; then
    echo "Expected unchanged Cargo version validation to fail." >&2
    exit 1
  fi
  grep -Fq 'Bump the Cargo package version before publishing.' <<< "$failure_output"
)
