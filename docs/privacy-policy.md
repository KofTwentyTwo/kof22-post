# KoF22 Postr privacy policy

Last updated: 2026-10-12

KoF22 Postr is an app for publishing posts and photos to [kof22.com](https://www.kof22.com).
It is made by James Maes (KofTwentyTwo). This page explains what the app does with your
information.

## Summary

- The app has **no analytics, no advertising and no tracking**. It does not use any
  third-party analytics or advertising SDK.
- Data leaves your device only when **you** publish to kof22.com, and it goes only to
  the KoF22 servers (`api.kof22.com`, `auth.kof22.com`, `s3.kof22.com`).
- In **Mock** mode (the default on a fresh install) nothing leaves your device.

## What is sent, and why

When you sign in and publish, the app sends to the KoF22 Site API:

| Data | Why |
| --- | --- |
| Your KoF22 account identity (email address and account ID, from the sign-in token) | To check that your account may publish |
| The text, title, tags, link and location label of a post | To publish the post |
| Photos you attach, with the alt text and captions you write | To publish them with the post |
| Photo location (GPS) | **Only** for a photo where you turn on "Keep this photo's location"; otherwise it is removed on your device before upload |

Published posts are public on kof22.com. Drafts and scheduled posts stay private on the
server until they are published.

## What stays on your device

- Sign-in tokens are stored in the iOS Keychain and are never logged.
- Queued posts, drafts and photos waiting to upload are stored in the app's private
  storage until they are sent.
- Your current location, when you tap "Use current location", is turned into a short
  place name on the device (Apple MapKit). Only the place name you keep is sent.

## Permissions

- **Photos (full access):** to attach original photos to posts.
- **Camera:** to take a photo for a post.
- **Location (when in use):** to fill in a place name for a post.
- **Notifications:** to tell you when a queued post is published or needs attention.

Each permission is optional; the app works without it.

## Sharing and retention

Your data is not sold or shared with third parties. Content you publish stays on
kof22.com until you delete it (you can delete posts in the app). Signing out revokes the
app's tokens and removes them from the device.

## Contact

Questions or requests: open an issue at
[github.com/KofTwentyTwo/kof22-post/issues](https://github.com/KofTwentyTwo/kof22-post/issues)
or use the contact form on [kof22.com](https://www.kof22.com).
