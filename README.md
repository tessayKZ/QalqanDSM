# QalqanDSM

A Flutter-based mobile application for secure communication within the Qalqan ecosystem.

## Overview

QalqanDSM (Decentralized Secure Messenger) is a cross-platform messaging app built on Flutter that enables encrypted text messaging, voice, and video calls. Leveraging the Matrix protocol, it offers decentralization, security, and scalability.

## Features

* **Encrypted Text Chats**: Send and receive end-to-end encrypted messages.
* **Voice & Video Calls**: High-quality calls via WebRTC with TURN server support.
* **Group Conversations**: Create and manage group chats.
* **End-to-End Encryption**: Implements Olm and Megolm encryption algorithms.
* **Push Notifications**: Receive instant alerts for new messages.

## Technology Stack

* **Flutter & Dart**: Single codebase for Android and iOS.
* **Matrix SDK**: Decentralized message federation and storage.
* **WebRTC/TURN**: Real-time audio and video communication.
* **SQLite**: Local caching and message history storage.

## Installation

1. Clone the repository:

   ```bash
   git clone https://github.com/tessayKZ/QalqanDSM.git
   cd QalqanDSM
   ```
2. Install dependencies:

   ```bash
   flutter pub get
   ```
3. Run the app on an emulator or device:

   ```bash
   flutter run
   ```

## Project Structure

```
QalqanDSM/          # Root directory
├── android/        # Android configuration files
├── ios/            # iOS configuration files
├── lib/            # Dart source code
│   ├── models/     # Data models
│   ├── screens/    # UI screens
│   ├── services/   # Backend services (Matrix, WebRTC, etc.)
│   └── widgets/    # Reusable UI components
├── assets/         # Static assets (icons, fonts)
├── test/           # Unit tests
└── pubspec.yaml    # Package configuration
```

## Contributing

Contributions, issues, and feature requests are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for details.

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for more information.
