# Dartus Flutter demo

This Flutter app mirrors the iOS sample by letting you upload a photo to Walrus and fetch it back with the blob ID.

## Run the demo
1. Install Flutter 3.35.0 (or newer) and enable the platforms you plan to test.
2. From this directory, fetch dependencies:
   ```bash
   flutter pub get
   ```
3. Generate platform folders since they are missing (keeps the file lightweight and more readable, hehe):
   ```bash
   flutter create . --platforms=android,ios,macos
   ```
4. Update iOS `ios/Runner/Info.plist` or where necessary with the photo library permissions required by `image_picker` (see plugin README, in case setup changes).
5. Launch the app:
   ```bash
   flutter run
   ```

The app uses the same testnet endpoints as the Swift demo. WalrusClient prints basic lifecycle logs to your run console automatically; call `setLogLevel(WalrusLogLevel.verbose)` in code if you need more detail.
