# Hipposphere DevOps

Reusable GitHub Actions and workflows for Hipposphere projects and other repos
that want to share Hipposphere release automation.

The workflows in this repository are meant to be called from consuming project
repositories. They install and call the Hippo CLI released from
`hipposphere/packages`:

```sh
hippo release docker generate
hippo release version packages/app
hippo release flutter build ios_app_store
```

Reusable workflows check out this repository internally before calling local
composite actions, so callers only need to reference the workflow path with a
ref.

## Setup Hippo

Use `actions/setup-hippo` when a workflow needs the `hippo` binary from
`hipposphere/packages`, generated Docker metadata, package version outputs, or a
short Hippo command.

```yaml
steps:
  - uses: actions/checkout@v5

  - id: hippo
    uses: hipposphere/devops/actions/setup-hippo@main
    with:
      version: 0.1.0
      docker-image: app
      package-version-path: packages/app
```

Useful outputs:

- `dockerfile`: generated Dockerfile path from `docker.yaml`
- `context`: Docker build context path
- `version`: package version from `pubspec.yaml`
- `version-tag`: tag-safe package version

Flutter projects can also set up Flutter and resolve dependencies:

```yaml
- uses: hipposphere/devops/actions/setup-hippo@main
  with:
    version: 0.1.0
    setup-flutter: "true"
    flutter-version: 3.44.0
    pub-get: "true"
```

## Build Docker Image

Call the reusable workflow from a project repo to build a Docker image from
`docker.yaml` and publish it to GHCR, upload it as a workflow artifact, or copy
the archive to a server over SSH.

```yaml
jobs:
  app-image:
    uses: hipposphere/devops/.github/workflows/build-docker-image.yml@main
    with:
      hippo_version: 0.1.0
      package_path: packages/app
      image: app
      image_name: my-app
      output: ghcr
```

The workflow publishes these tags for `output: ghcr`:

- `ghcr.io/<owner>/<image_name>:<version-tag>`
- `ghcr.io/<owner>/<image_name>:latest`
- `ghcr.io/<owner>/<image_name>:sha-<commit-sha>`

## Release Flutter

Call the generic Flutter release workflow from a project repo for one configured
target from `flutter_release.yaml`.

```yaml
jobs:
  ios:
    uses: hipposphere/devops/.github/workflows/release-flutter.yml@main
    with:
      hippo_version: 0.1.0
      target: ios_app_store
      runner: macos-15
      setup_ios_signing: true
      publish_ios_app_store: true
    secrets: inherit
```

The workflow builds with:

```sh
hippo release flutter build --github-output <target>
```

When `publish_ios_app_store` is enabled, it then runs:

```sh
hippo release flutter publish ios-app-store --target <target>
```
