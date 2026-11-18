<p align="center">
 <img width=200px height=200px src="assets/app_icons/icon-red.png"/>
</p>

<h1 align="center">Mangayomi — Stremio fork</h1>

<div align="center">

[![Fork releases](https://img.shields.io/github/downloads/deangulbairy/experiment/total?label=fork%20downloads&labelColor=27303D&color=0D1117&logo=github&logoColor=FFFFFF&style=flat)](https://github.com/deangulbairy/experiment/releases)
[![Upstream Mangayomi](https://img.shields.io/github/stars/kodjodevf/mangayomi)](https://github.com/kodjodevf/mangayomi)

An independent Mangayomi fork adding Stremio movie and TV browsing alongside the existing manga, novel, and anime features.
</div>

> [!NOTE]
> This is an independent fork maintained at [deangulbairy/experiment](https://github.com/deangulbairy/experiment). It is not an official Mangayomi release. Use this repository's releases and AltStore source for the Stremio-enabled build.

## What's included

This fork keeps Mangayomi's manga, webtoon, comic, novel, and anime features, and adds a **Movies & TV** section powered by Stremio-compatible add-ons:

- Starts with Cinemeta for movie and series catalogs.
- Add and remove add-ons by manifest URL; installed add-ons are saved on the device.
- Browse movie and series catalogs, and use search or catalog filters when an add-on supports them.
- Open title details and series episodes, then request streams from installed streaming add-ons.
- List series episodes in season and episode order, with the earliest episode first.
- Episode stream results appear under the episode you select, with a visible loading state.
- Play direct HTTP(S) streams and magnet/torrent streams in a full-screen player that uses the same video output as anime playback and shows playback errors instead of silently remaining black.
- Anime episodes, movies, and shows are added to the **Watch** library when playback starts; progress is saved on-device so playback can resume later. A show's card resumes its most recently played episode.
- The **Watch** activity combines anime history with the movie and TV continue-watching shelf.
- Cast anime, movies, and shows to a Chromecast on the same Wi-Fi network, with a playback remote and support for stream request headers.
- Manage movie and TV add-on manifest URLs in Browse settings, alongside the Manga, Anime, and Novel repository controls.

Stremio support currently covers movie and series catalogs, metadata, and streams. Catalogs and playable sources depend on the add-ons you install; add-ons that expose other Stremio resource types are not shown in this section.

On iOS, allow Mangayomi to access the local network when prompted so it can discover Chromecast devices. If discovery was denied, enable it under **Settings → Privacy & Security → Local Network**. Chromecast support is adapted from [IStoleThis/chromecast-testing](https://github.com/IStoleThis/chromecast-testing); see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

The rest of Mangayomi includes local reading, configurable readers, anime and manga tracking (MyAnimeList, AniList, SIMKL, Trakt, and Kitsu), library categories, themes, and local backups.

## Download

Download builds from the [fork's Releases page](https://github.com/deangulbairy/experiment/releases). The iOS IPA is published by the `Publish iOS IPA` GitHub Actions workflow after the app version changes. Its AltStore source is updated from the fork's releases.

## iOS sideloading sources

Add the fork's source to AltStore, Feather, or SideStore. The source lists the fork-built IPA and receives updates when a new iOS release is published.

<a href="https://intradeus.github.io/http-protocol-redirector?r=altstore://source?url=https://raw.githubusercontent.com/deangulbairy/experiment/refs/heads/main/repo/source.json"><img alt="Add to AltStore" src="repo/images/buttons/altstore_button.png" width="150"></a>
&nbsp;
<a href="https://intradeus.github.io/http-protocol-redirector?r=feather://source/https://raw.githubusercontent.com/deangulbairy/experiment/refs/heads/main/repo/source.json"><img alt="Add to Feather" src="repo/images/buttons/feather_button.png" width="150"></a>
&nbsp;
<a href="https://intradeus.github.io/http-protocol-redirector?r=sidestore://source?url=https://raw.githubusercontent.com/deangulbairy/experiment/refs/heads/main/repo/source.json"><img alt="Add to SideStore" src="repo/images/buttons/sidestore_button.png" width="150"></a>
&nbsp;
<a href="https://raw.githubusercontent.com/deangulbairy/experiment/refs/heads/main/repo/source.json"><img alt="Open source JSON" src="repo/images/buttons/url_button.png" width="150"></a>

The IPA is packaged without a distribution certificate. AltStore/SideStore signs it for your device during sideloading. The source is [repo/source.json](https://raw.githubusercontent.com/deangulbairy/experiment/refs/heads/main/repo/source.json).

## Contributing

Contributions are welcome. For Mangayomi extension development, see the upstream guides for [Dart sources](https://github.com/kodjodevf/mangayomi-extensions/blob/main/CONTRIBUTING-DART.md) and [JavaScript sources](https://github.com/kodjodevf/mangayomi-extensions/blob/main/CONTRIBUTING-JS.md).

## Building from source

Install the [Flutter SDK](https://docs.flutter.dev/get-started/install), the [Rust toolchain](https://www.rust-lang.org/tools/install), and the `flutter_rust_bridge_codegen` CLI:

```bash
rustc --version
flutter doctor
cargo install flutter_rust_bridge_codegen
flutter_rust_bridge_codegen generate
flutter pub get
flutter run
```

The iOS IPA workflow runs on a macOS GitHub Actions runner. It builds the iOS app without a developer distribution certificate, packages the IPA, publishes a GitHub Release, and refreshes the AltStore source.

## License

    Copyright 2023 Moustapha Kodjo Amadou

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.

## Disclaimer

Mangayomi does not host content and is not affiliated with content providers. Only install add-ons and access media you are authorized to use.
