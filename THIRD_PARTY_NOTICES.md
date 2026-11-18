# Third-party components

WatchRelay's original code is distributed under the [MIT License](LICENSE).
Dependencies and downloaded tools retain their upstream licenses.

- The Gradle wrapper scripts and JAR are provided by Gradle under
  [Apache License 2.0](https://github.com/gradle/gradle/blob/v8.14.0/LICENSE).
  The wrapper's existing copyright and license notices are preserved.
- Mac-wide mode downloads the official sing-box engine and can use its SFM
  client. Those programs are separate dependencies under their
  [upstream license](https://github.com/SagerNet/sing-box/blob/v1.14.4/LICENSE).
  Their binaries are excluded from this source repository. The staging
  script retrieves and preserves the engine's license alongside it.
- Android Gradle Plugin, Kotlin, JUnit, and platform SDKs are resolved by
  the build. Their artifacts are excluded from this source repository.
