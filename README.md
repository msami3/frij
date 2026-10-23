# frij
iOS app for organizing your fridge: track what you have, see what's expiring, and waste less food.

## Features

- Sign in with Google (Firebase Authentication)
- After first sign-in, name your first fridge; add more fridges later
- Add food items with an expiration date, grouped into Expired / Expiring Soon / Fresh
- Data syncs through Cloud Firestore under `users/{uid}/fridges/{fridgeID}/items/{itemID}`, and works offline
- **Add by Voice**: a conversational assistant that can only add food, rename or redate items, and end the conversation
  - Uses Apple's on-device model (Apple Intelligence) when available, otherwise Gemini through Firebase AI Logic
  - Speech-to-text and the spoken voice run on the device

Requires Xcode 26+ (for Apple's Foundation Models), iOS 17+. Add by Voice needs a real device to test speech input: the simulator can't run Apple's speech recognizer.

## Setup

### 1. Tools

```sh
brew install xcodegen
```

The Xcode project is generated from `project.yml` and is not checked in.

### 2. Firebase project

1. Create a project at https://console.firebase.google.com.
2. **Add an iOS app** with your bundle ID (for example `com.yourname.frij`).
3. Download `GoogleService-Info.plist` and put it at `Frij/GoogleService-Info.plist`. It's gitignored.
4. **Authentication → Sign-in method → Google**: enable it.
5. **Firestore Database → Create database**. Then paste the contents of `firestore.rules` into the **Rules** tab and publish, so each user can only access their own data.
6. **AI Logic → Get started → Gemini Developer API**, for the voice assistant on devices without Apple Intelligence.
7. **App Check** is enforced for AI Logic. Debug builds use App Check's debug provider: on first launch, each simulator or device prints a line containing `debug token: …` in the Xcode console. Add it under **App Check → Apps → your iOS app → ⋮ → Manage debug tokens**. Keep these tokens private.

### 3. Local config

```sh
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig
```

Fill in:
- `PRODUCT_BUNDLE_IDENTIFIER`: the same bundle ID you registered in Firebase
- `GOOGLE_REVERSED_CLIENT_ID`: the `REVERSED_CLIENT_ID` value from `GoogleService-Info.plist`
- `DEVELOPMENT_TEAM`: your Apple team ID (only needed on a physical device)

### 4. Generate and run

```sh
xcodegen generate
open Frij.xcodeproj
```

Re-run `xcodegen generate` whenever you add or remove files.

## Project layout

```
Frij/
  App/        FrijApp: Firebase startup
  Models/     Fridge, FoodItem (Firestore Codable)
  Services/   AuthService (Google sign-in), FridgeStore, FridgeItemsStore (live Firestore listeners)
    Assistant/  FoodAssistant (conversation, instructions, tools), OnDeviceBrain / CloudBrain (models),
                SpeechRecognizer, Speaker, CloudVoice (Gemini TTS, currently off), SpokenDateParser
  Views/      RootView routing, SignIn, CreateFridge, FridgeList, FridgeDetail, FoodItemForm, FoodAssistantView
Config/       xcconfig files (Secrets.xcconfig is per-developer)
firestore.rules
```
