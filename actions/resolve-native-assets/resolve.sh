#!/usr/bin/env bash

set -euo pipefail

config_path="${NATIVE_CONFIG_PATH:-.hippo/native-assets.json}"
package_scope="${NATIVE_PACKAGE_SCOPE:-}"
dry_run="${NATIVE_DRY_RUN:-true}"
repository_context="${GITHUB_REPOSITORY:-}"
repository_owner="${GITHUB_REPOSITORY_OWNER:-${repository_context%%/*}}"

if [[ -z "$repository_context" || "$repository_context" != */* || -z "$repository_owner" ]]; then
  echo "::error::GITHUB_REPOSITORY and its owner must identify the calling repository."
  exit 1
fi

if [[ "$dry_run" != "true" && "$dry_run" != "false" ]]; then
  echo "::error::dry-run must be true or false."
  exit 1
fi

if [[ ! -f "$config_path" ]]; then
  echo "No native asset manifest at $config_path; skipping native assets."
  echo 'targets=[]' >> "$GITHUB_OUTPUT"
  echo 'missing_count=0' >> "$GITHUB_OUTPUT"
  echo 'native_packages=[]' >> "$GITHUB_OUTPUT"
  exit 0
fi

jq -e '
  .version == 1 and
  (.packages | type == "object") and
  all(.packages[];
    (.crate | type == "string") and
    (.native_inputs | type == "array") and
    (.native_inputs | length > 0)
  )
' "$config_path" >/dev/null || {
  echo "::error::Invalid native asset manifest: $config_path"
  exit 1
}

targets_file="$(mktemp)"
packages_file="$(mktemp)"
releases_file="$(mktemp)"
trap 'rm -f "$targets_file" "$packages_file" "$releases_file"' EXIT

resolve_target() {
  local target_name="$1"
  case "$target_name" in
    linux-x64)
      printf '%s\t%s\t%s\t%s\n' linux x64 x86_64-unknown-linux-gnu ubuntu-latest
      ;;
    linux-arm64)
      printf '%s\t%s\t%s\t%s\n' linux arm64 aarch64-unknown-linux-gnu ubuntu-24.04-arm
      ;;
    macos-arm64)
      printf '%s\t%s\t%s\t%s\n' macos arm64 aarch64-apple-darwin macos-14
      ;;
    *)
      echo "::error::Unsupported native target '$target_name'." >&2
      return 1
      ;;
  esac
}

while IFS= read -r package; do
  if [[ -n "$package_scope" && "$package" != "$package_scope" ]]; then
    continue
  fi

  crate="$(jq -r --arg package "$package" '.packages[$package].crate' "$config_path")"
  if [[ "$crate" = /* || "$crate" == *".."* || ! -f "$crate" ]]; then
    echo "::error::Native crate for $package must be an existing repository-relative path: $crate"
    exit 1
  fi

  cargo_package="$(jq -r --arg package "$package" '.packages[$package].cargo_package // $package' "$config_path")"
  version="$(sed -nE 's/^version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$crate" | head -1)"
  if [[ -z "$version" ]]; then
    echo "::error::Could not read the Cargo package version from $crate"
    exit 1
  fi

  crate_dir="$(dirname "$crate")"
  toolchain_file="$(jq -r --arg package "$package" '.packages[$package].toolchain // empty' "$config_path")"
  if [[ -z "$toolchain_file" ]]; then
    toolchain_file="$crate_dir/rust-toolchain.toml"
  fi
  if [[ "$toolchain_file" = /* || "$toolchain_file" == *".."* || ! -f "$toolchain_file" ]]; then
    echo "::error::Rust toolchain for $package must be an existing repository-relative path: $toolchain_file"
    exit 1
  fi
  toolchain="$(sed -nE 's/^channel[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$toolchain_file" | head -1)"
  if [[ -z "$toolchain" ]]; then
    echo "::error::Could not read the Rust channel from $toolchain_file"
    exit 1
  fi

  jq -cn --arg package "$package" '$package' >> "$packages_file"
  tag="$package-native-v$version"
  release_owner="$(
    jq -r --arg package "$package" \
      '.packages[$package].release_owner // empty' "$config_path"
  )"
  if [[ -z "$release_owner" ]]; then
    release_owner="$repository_owner"
  fi
  release_repository="$(
    jq -r --arg package "$package" \
      '.packages[$package].release_repository // empty' "$config_path"
  )"
  if [[ -z "$release_repository" ]]; then
    release_repository="${repository_context#*/}"
  fi
  if [[ "$release_owner" == */* || -z "$release_owner" || "$release_repository" == */* || -z "$release_repository" ]]; then
    echo "::error::release_owner and release_repository for $package must be non-empty GitHub name components."
    exit 1
  fi
  release_repo="$release_owner/$release_repository"
  release_exists=false
  assets=""
  if gh release view "$tag" --repo "$release_repo" >/dev/null 2>&1; then
    release_exists=true
    release_json="$(
      gh release view "$tag" --repo "$release_repo" --json assets,body
    )"
    assets="$(jq -r '.assets[].name' <<< "$release_json")"
    release_body="$(jq -r '.body // ""' <<< "$release_json")"

    native_inputs=()
    while IFS= read -r native_input; do
      native_inputs+=("$native_input")
    done < <(jq -r --arg package "$package" '.packages[$package].native_inputs[]' "$config_path")
    for native_input in "${native_inputs[@]}"; do
      if [[ "$native_input" = /* || "$native_input" == *".."* ]]; then
        echo "::error::native_inputs for $package must be repository-relative paths."
        exit 1
      fi
    done

    source_repository="$(
      sed -n 's/^Hippolabs-Native-Source-Repository: //p' <<< "$release_body" | head -1
    )"
    source_commit="$(
      sed -n 's/^Hippolabs-Native-Source-Commit: //p' <<< "$release_body" | head -1
    )"
    if [[ -n "$source_repository" || -n "$source_commit" ]]; then
      if [[ "$source_repository" != "$repository_context" || -z "$source_commit" ]]; then
        echo "::error::$tag in $release_repo belongs to another source repository or has invalid provenance."
        exit 1
      fi
      if ! git cat-file -e "$source_commit^{commit}" 2>/dev/null; then
        git fetch origin "$source_commit"
      fi
      comparison_ref="$source_commit"
    else
      if [[ "$release_repo" != "$repository_context" ]]; then
        echo "::error::$tag in $release_repo has no source provenance. Bump the Cargo version to create a traceable release."
        exit 1
      fi
      if ! git rev-parse --verify --quiet "refs/tags/$tag" >/dev/null; then
        git fetch --force origin "refs/tags/$tag:refs/tags/$tag"
      fi
      comparison_ref="$tag"
    fi

    if ! git diff --quiet "$comparison_ref"...HEAD -- "${native_inputs[@]}"; then
      echo "::error::Native inputs for $package changed after $tag. Bump the Cargo package version before publishing."
      exit 1
    fi
  fi

  package_targets=()
  while IFS= read -r package_target; do
    package_targets+=("$package_target")
  done < <(
    jq -r --arg package "$package" \
      '.packages[$package].targets // ["linux-x64", "linux-arm64", "macos-arm64"] | .[]' \
      "$config_path"
  )
  linux_packages="$(jq -c --arg package "$package" '.packages[$package].linux_packages // ["pkg-config"]' "$config_path")"
  macos_packages="$(jq -c --arg package "$package" '.packages[$package].macos_packages // []' "$config_path")"
  prepare_script="$(jq -r --arg package "$package" '.packages[$package].prepare_script // ""' "$config_path")"
  library_base="$(jq -r --arg package "$package" '.packages[$package].library_base // $package' "$config_path")"

  if [[ -n "$prepare_script" && ( "$prepare_script" = /* || "$prepare_script" == *".."* || ! -f "$prepare_script" ) ]]; then
    echo "::error::prepare_script for $package must be an existing repository-relative path."
    exit 1
  fi

  package_missing=false
  for target_name in "${package_targets[@]}"; do
    IFS=$'\t' read -r os arch triple runner < <(resolve_target "$target_name")
    case "$os" in
      linux) library="lib${library_base}.so" ;;
      macos) library="lib${library_base}.dylib" ;;
    esac

    artifact="$package-$version-$os-$arch-$library"
    if grep -Fxq "$artifact" <<< "$assets" && grep -Fxq "$artifact.sha256" <<< "$assets"; then
      echo "Native artifact already exists: $artifact"
      continue
    fi

    package_missing=true
    source=".dart_tool/native-assets/$package/$triple/release/$library"
    jq -cn \
      --arg package "$package" \
      --arg version "$version" \
      --arg toolchain "$toolchain" \
      --arg crate "$crate" \
      --arg cargo_package "$cargo_package" \
      --arg os "$os" \
      --arg arch "$arch" \
      --arg triple "$triple" \
      --arg runner "$runner" \
      --arg library "$library" \
      --arg artifact "$artifact" \
      --arg source "$source" \
      --arg prepare_script "$prepare_script" \
      --arg release_owner "$release_owner" \
      --arg release_repository "$release_repository" \
      --argjson linux_packages "$linux_packages" \
      --argjson macos_packages "$macos_packages" \
      '{package:$package, version:$version, toolchain:$toolchain, crate:$crate,
        cargo_package:$cargo_package, os:$os, arch:$arch, triple:$triple,
        runner:$runner, library:$library, artifact:$artifact, source:$source,
        prepare_script:$prepare_script, release_owner:$release_owner,
        release_repository:$release_repository, linux_packages:$linux_packages,
        macos_packages:$macos_packages}' >> "$targets_file"
  done

  if [[ "$package_missing" == "true" && "$release_exists" == "false" && "$dry_run" == "false" ]]; then
    jq -cn \
      --arg tag "$tag" \
      --arg repository "$release_repo" \
      '{tag:$tag, repository:$repository}' >> "$releases_file"
  fi
done < <(jq -r '.packages | keys[]' "$config_path")

if [[ "$dry_run" == "false" ]]; then
  while IFS= read -r release; do
    [[ -n "$release" ]] || continue
    tag="$(jq -r '.tag' <<< "$release")"
    repository="$(jq -r '.repository' <<< "$release")"
    if gh release view "$tag" --repo "$repository" >/dev/null 2>&1; then
      continue
    fi
    if [[ "$repository" == "$repository_context" ]]; then
      target="$GITHUB_SHA"
    else
      target="$(gh repo view "$repository" --json defaultBranchRef --jq '.defaultBranchRef.name')"
    fi
    notes="$(printf '%s\n%s\n' \
      "Hippolabs-Native-Source-Repository: $repository_context" \
      "Hippolabs-Native-Source-Commit: $GITHUB_SHA")"
    gh release create "$tag" \
      --repo "$repository" \
      --target "$target" \
      --title "$tag" \
      --notes "$notes"
  done < "$releases_file"
fi

targets="$(jq -cs '.' "$targets_file")"
native_packages="$(jq -cs '.' "$packages_file")"
missing_count="$(jq 'length' <<< "$targets")"

echo "targets=$targets" >> "$GITHUB_OUTPUT"
echo "missing_count=$missing_count" >> "$GITHUB_OUTPUT"
echo "native_packages=$native_packages" >> "$GITHUB_OUTPUT"
