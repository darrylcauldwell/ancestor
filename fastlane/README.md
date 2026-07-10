fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## Mac

### mac beta

```sh
[bundle exec] fastlane mac beta
```

Push a new beta build to TestFlight

### mac metadata

```sh
[bundle exec] fastlane mac metadata
```

Upload metadata and screenshots to App Store Connect

### mac promote

```sh
[bundle exec] fastlane mac promote
```

Submit existing TestFlight build to App Store review

### mac build

```sh
[bundle exec] fastlane mac build
```

Build and archive without uploading

### mac test

```sh
[bundle exec] fastlane mac test
```

Run tests

----


## iOS

### ios beta

```sh
[bundle exec] fastlane ios beta
```

Push a new Ancestor Viewer (iOS) beta build to TestFlight

----


## tvos

### tvos beta

```sh
[bundle exec] fastlane tvos beta
```

Push a new Ancestor Viewer (tvOS) beta build to TestFlight

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
