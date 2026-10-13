# Apex AI

Apex AI is an Android-first, local-first intelligent assistant built with Flutter.
It helps users search their device, find documents and OCR text, launch apps,
understand natural-language commands, make web searches, and optionally use
AI chat with relevant document context.

## What it can do

- Search installed apps, contacts, documents, and indexed OCR text.
- Understand actions such as opening an app, finding a document, navigating,
  playing music, or starting a web search.
- Build a local document knowledge index for fast, offline retrieval.
- Use on-device OCR for supported documents and images.
- Offer optional Gemini-powered chat with user-provided API credentials.
- Keep core device search and document retrieval available offline.

## Tech stack

- Flutter and Dart for the interface and product logic.
- Kotlin/Android for device integration, document indexing and OCR.
- SQLite-based local search indexes and native vector search.
- Firebase for optional authentication and small account-level settings sync.
- Optional Cloudflare Worker backend for cloud-index experiments.

## Run locally

Install Flutter, Android Studio, and an Android SDK. Then run:

```sh
flutter pub get
flutter analyze
flutter test
flutter run
```

The app is Android-first. Native contact discovery, document indexing, OCR and
device actions require an Android device or emulator.

## Local configuration and secrets

No production API key, service credential, signing key, or Firebase client
configuration is included in this repository.

- Create your own Firebase project and place its generated Android client file
  at `android/app/google-services.json`. This file is intentionally ignored by Git.
- Add Cloudflare Worker secrets only in the provider dashboard or a local
  `cloudflare/worker/.dev.vars` file. Start from `.dev.vars.example`.
- Gemini access uses a key supplied by the user on their own device; do not
  commit shared keys to source control.

## Privacy

Apex AI is designed to be local-first: contacts, device metadata and document
indexes remain on the device unless a user explicitly enables a cloud feature.
Before distributing the app, review Android permissions, Firebase rules,
backend access controls and the privacy policy for your deployment.

## Release builds

Use the repository release script for an installable ARM64 APK:

```powershell
./tool/build_release.ps1
```

Release signing material and generated build artifacts must remain outside Git.

## Status

This is an actively developed prototype. APIs, supported integrations and
storage formats may change before a production release.
