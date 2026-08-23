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
    GITHUB_OUTPUT="$output" \
    NATIVE_CONFIG_PATH=native-assets.json \
    NATIVE_DRY_RUN=true \
    bash "$devops_root/actions/resolve-native-assets/resolve.sh"

  targets="$(sed -n 's/^targets=//p' "$output")"
  [[ "$(jq 'length' <<< "$targets")" == "3" ]]
  [[ "$(jq -r '.[0].package' <<< "$targets")" == "example_native" ]]
  [[ "$(sed -n 's/^missing_count=//p' "$output")" == "3" ]]

  : > "$output"
  PATH="$fixture/bin:$PATH" \
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
