# Dartus Example

A minimal Flutter app demonstrating the Dartus SDK's HTTP mode.

## Features

- **Upload Tab** — Pick an image from your device and upload it to Walrus testnet via `WalrusClient.putBlob()`
- **Fetch Tab** — Enter a blob ID and download the image via `WalrusClient.getBlobByObjectId()`

## Running

```bash
cd Dartus/example
flutter pub get
flutter run -d macos    # macOS
flutter run -d ios      # iOS simulator
flutter run -d android  # Android emulator
```

## Configuration

The app uses official Walrus testnet endpoints by default:

- Publisher: `https://publisher.walrus-testnet.walrus.space`
- Aggregator: `https://aggregator.walrus-testnet.walrus.space`

Edit the `WalrusManager` constructor in `lib/main.dart` to change endpoints.

## Platform Notes

- **macOS** — Network entitlements are pre-configured.
- **iOS** — Photo library permission (`NSPhotoLibraryUsageDescription`) is in `Info.plist`.
- **Android** — Works out of the box.

## Full Showcase App

For a comprehensive demo covering all Dartus features (HTTP uploads, direct-mode reads/writes, wallet management, quilts, encoding, BLS, system state), see the [Dartus-Demo](https://github.com/Immadominion/Dartus-Demo) repository.
