<div align="center">
  <img src="assets/logo.png" width="88" alt="Lumino logo">
  <h1>Lumino</h1>
  <p><strong>Your music. Your space.</strong><br>A desktop music player built with Flutter.</p>
  <p>
    <a href="https://github.com/theLuni/lumino/releases/latest"><img src="https://img.shields.io/github/v/release/theLuni/lumino?display_name=tag&style=for-the-badge&color=8b5cf6" alt="Latest release"></a>
    <img src="https://img.shields.io/badge/Flutter-3.27%2B-54c5f8?style=for-the-badge&logo=flutter&logoColor=white" alt="Flutter 3.27 or newer">
    <img src="https://img.shields.io/badge/Platform-Windows-111111?style=for-the-badge&logo=windows&logoColor=white" alt="Windows desktop">
  </p>
</div>

<br>

## About

Lumino is a music player focused on a calm, immersive listening experience. Browse your music, build a library, and let the fullscreen player put the controls and artwork front and center.

<div align="center">
  <img src="assets/screenshot-home.png" width="100%" alt="Lumino home screen with quick access, daily mixes, and playback controls">
</div>

## Take a closer look

<table>
  <tr>
    <td width="50%" align="center">
      <strong>Fullscreen listening</strong><br><br>
      <img src="assets/screenshot-fullscreen.png" width="100%" alt="Lumino fullscreen player">
    </td>
    <td width="50%" align="center">
      <strong>Make it yours</strong><br><br>
      <img src="assets/screenshot-settings.png" width="100%" alt="Lumino appearance and player settings">
    </td>
  </tr>
</table>

## Features

- **A focused player** — playback controls, queue, shuffle, repeat, and a fullscreen listening view.
- **Your music in one place** — home, search, liked songs, playlists, and artist pages.
- **Personal touches** — dark, light, and black themes, plus configurable fullscreen artwork and blur.
- **Share and discover** — chat, share tracks, and explore recommendations.
- **Keep Lumino current** — check GitHub releases on sign-in or manually from Settings on Windows.

## Download

Get the latest Windows installer from **[GitHub Releases](https://github.com/theLuni/lumino/releases/latest)**.

## Run from source

You’ll need Flutter 3.27 or newer and the Windows desktop development tools configured for Flutter.

```powershell
git clone https://github.com/theLuni/lumino-app.git
cd lumino-app
flutter pub get
flutter run -d windows
```

To build a Windows release bundle:

```powershell
flutter build windows --release
```

On Windows, run [`build_release.bat`](build_release.bat) to set the app version, build Debug and Release, create the Inno Setup installer, and generate a `version.txt` report in `release_output`.

## Built with

[Flutter](https://flutter.dev/) · [Dart](https://dart.dev/) · [media_kit](https://pub.dev/packages/media_kit)
