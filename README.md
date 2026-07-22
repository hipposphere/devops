# Hipposphere DevOps

Reusable GitHub Actions for Hipposphere projects and other repos
that want to share Hipposphere release automation.

The actions in this repository are used as steps in consuming project workflows.
They install and call the Hippo CLI released from
`hipposphere/packages`:

```sh
hippo release docker generate
hippo release version packages/app
hippo release flutter build ios_app_store
```

The release actions check out the consuming repository themselves. Configure
the runner, GitHub environment, and permissions on the calling job.

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
          hippo_version: 0.1.0
          package_path: packages/app
          image: app
          image_name: my-app
          output: ghcr
```

The action publishes these tags for `output: ghcr`:

- `ghcr.io/<owner>/<image_name>:<version-tag>`
- `ghcr.io/<owner>/<image_name>:latest`
- `ghcr.io/<owner>/<image_name>:sha-<commit-sha>`

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
          hippo_version: 0.1.0
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
