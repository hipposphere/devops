# Hipposphere DevOps

Reusable GitHub Actions for Hipposphere projects and other repos
that want to share Hipposphere release automation.

The actions in this repository are used as steps in consuming project workflows.
They install and call the Hippo CLI released from
`hipposphere/hippo-cli`:

```sh
hippo release docker generate
hippo release version packages/app
hippo release flutter build ios_app_store
```

The release actions check out the consuming repository themselves. Configure
the runner, GitHub environment, and permissions on the calling job.

## Publish Dart Packages

Use the reusable workflow to validate and publish a Dart Pub workspace. It can
discover Rust-backed packages, build only missing native release assets, and
wait for those assets before publishing to Pub.

```yaml
name: Publish

on:
  workflow_dispatch:
    inputs:
      package_scope:
        required: false
        default: ""
      dry_run:
        type: boolean
        default: false

permissions:
  contents: write

jobs:
  publish:
    uses: hipposphere/devops/.github/workflows/publish-dart-packages.yml@main
    with:
      package_scope: ${{ inputs.package_scope }}
      dry_run: ${{ inputs.dry_run }}
      devops_ref: main
    secrets:
      pub_credentials: ${{ secrets.PUB_CREDENTIALS }}
      native_artifacts_token: ${{ secrets.NATIVE_ARTIFACTS_TOKEN }}
```

Publication is the default. Set `dry_run: true` explicitly to validate without
creating releases, building artifacts, or publishing packages.

Use a release tag such as `@v1` for both the reusable workflow reference and
`devops_ref` once that tag exists. The caller must grant `contents: write`
because a real release can create native GitHub releases and upload assets.
Dry runs do not create releases or upload native assets.

Native packages are declared in `.hippo/native-assets.json`. Repositories
without this file skip native work automatically. See
[`examples/native-assets.json`](examples/native-assets.json) for a complete
example.

```json
{
  "version": 1,
  "packages": {
    "dart_http_server_runtime": {
      "crate": "packages/dart_http_server_runtime/rust/Cargo.toml",
      "native_inputs": ["packages/dart_http_server_runtime/rust"],
      "targets": ["linux-x64", "linux-arm64", "macos-arm64"],
      "linux_packages": ["pkg-config"]
    }
  }
}
```

Supported target names are `linux-x64`, `linux-arm64`, and `macos-arm64`.
Optional package fields are:

- `cargo_package`: Cargo package name when it differs from the Dart package.
- `toolchain`: repository-relative `rust-toolchain.toml` override.
- `library_base`: dynamic library basename without `lib` or its extension.
- `release_owner` and `release_repository`: GitHub release destination. They
  default to the calling repository. Cross-repository destinations require a
  `native_artifacts_token` with release write access.
- `linux_packages` and `macos_packages`: system packages installed before the
  build.
- `prepare_script`: repository-relative Bash script for package-specific native
  preparation. It receives `NATIVE_PACKAGE`, `NATIVE_TARGET_OS`,
  `NATIVE_TARGET_ARCH`, and `NATIVE_TARGET_TRIPLE`.

Native releases use `<package>-native-v<cargo-version>` tags. Artifacts use
`<package>-<cargo-version>-<os>-<arch>-<library>` names and include a matching
`.sha256` file. If native inputs changed after the current native release tag,
the workflow fails and requires a Cargo version bump instead of silently
reusing stale binaries.

## Setup Hippo

Use `actions/setup-hippo` when a workflow needs the `hippo` binary from
`hipposphere/hippo-cli`, generated Docker metadata, package version outputs, or a
short Hippo command.

```yaml
steps:
  - uses: actions/checkout@v5

  - id: hippo
    uses: hipposphere/devops/actions/setup-hippo@main
    with:
      version: 0.1.3
      docker-image: app
```

Useful outputs:

- `dockerfile`: generated Dockerfile path from `docker.yaml`
- `context`: Docker build context path
- `version`: package version from `pubspec.yaml`
- `version-tag`: tag-safe package version

`setup-hippo` only generates Docker inputs. The consuming build action owns the
subsequent `docker buildx build` invocation so it can select platforms, tags,
caches, and its output mode.

Flutter projects can also set up Flutter and resolve dependencies:

```yaml
- uses: hipposphere/devops/actions/setup-hippo@main
  with:
    version: 0.1.3
    setup-flutter: "true"
    flutter-channel: stable
    flutter-version: 3.44.0
    pub-get: "true"
```

## Build Docker Image

Use the action from a project workflow to build a Docker image from
`docker.yaml` and publish it to GHCR, upload it as a workflow artifact, or copy
the archive to a server over SSH.

```yaml
jobs:
  app-image:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: hipposphere/devops/actions/build-docker-image@main
        with:
          hippo_version: 0.1.3
          image: app
          image_name: my-app
          output: ghcr
```

The action publishes these tags for `output: ghcr`:

- `ghcr.io/<owner>/<image_name>:v<version-tag>`
- `ghcr.io/<owner>/<image_name>:latest`
- `ghcr.io/<owner>/<image_name>:sha-<commit-sha>`

## Deploy Docker

Use the deploy action to copy Compose configuration and optional environment or
Docker image files to a server over SSH, then start the remote Compose stack.
The calling workflow must check out the repository or otherwise prepare the
configured source files before invoking the action.

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    permissions:
      contents: read
      packages: read
    steps:
      - uses: actions/checkout@v5

      - uses: hipposphere/devops/actions/deploy-docker@main
        with:
          source: deploy
          target: /home/deploy/app
          ssh_host: ${{ vars.SSH_HOST }}
          ssh_port: ${{ vars.SSH_PORT || '22' }}
          ssh_username: ${{ vars.SSH_USERNAME }}
          ssh_key: ${{ secrets.SSH_KEY }}
          ssh_password: ${{ secrets.SSH_PASSWORD }}
          env_file: ${{ secrets.APP_ENV }}
          login_ghcr: "true"
          ghcr_username: ${{ github.actor }}
          ghcr_token: ${{ secrets.GITHUB_TOKEN }}
```

## Release Flutter

Use the generic Flutter release action from a project workflow for one configured
target from `flutter_release.yaml`.

```yaml
jobs:
  ios:
    runs-on: macos-15
    environment: release
    permissions:
      contents: read
    steps:
      - uses: hipposphere/devops/actions/release-flutter@main
        with:
          hippo_version: 0.1.3
          target: ios_app_store
          setup_ios_signing: "true"
          publish_ios_app_store: "true"
          app_store_connect_key_id: ${{ secrets.APP_STORE_CONNECT_KEY_ID }}
          app_store_connect_issuer_id: ${{ secrets.APP_STORE_CONNECT_ISSUER_ID }}
          app_store_connect_private_key: ${{ secrets.APP_STORE_CONNECT_PRIVATE_KEY }}
          ios_distribution_certificate_base64: ${{ secrets.IOS_DISTRIBUTION_CERTIFICATE_BASE64 }}
          ios_distribution_certificate_password: ${{ secrets.IOS_DISTRIBUTION_CERTIFICATE_PASSWORD }}
          ios_provisioning_profiles_base64: ${{ secrets.IOS_PROVISIONING_PROFILES_BASE64 }}
```

The action builds with:

```sh
hippo release flutter build --github-output <target>
```

When `publish_ios_app_store` is enabled, it then runs:

```sh
hippo release flutter publish ios-app-store --target <target>
```
