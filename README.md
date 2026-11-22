<p align="center">
  <img src="https://foreverlm.com/assets/app-icon.png" alt="" width="88">
</p>

<h1 align="center">ForeverLM</h1>

<p align="center">
  <strong>Learn frictionlessly.</strong><br>
  Chat with your whole library of sources, learn it with a smart AI tutor,<br>
  and make flashcards, audio and video overviews.
</p>

<p align="center">
  <a href="https://foreverlm.com/releases/ForeverLM.dmg"><strong>Download for Mac</strong></a>
  &middot; <a href="https://foreverlm.com">Website</a>
  &middot; <a href="https://docs.foreverlm.com">Docs</a><br>
  30 days free, then $19 once. No subscription.
</p>

<p align="center">
  <img src="https://foreverlm.com/assets/home/notebook.jpg" alt="A ForeverLM notebook: sources on the left, a chat in the middle, and Studio on the right with audio and video overviews, cards and reports">
</p>

- **Chat with your whole library.** Papers, books, articles, podcasts, YouTube
  and X posts, with every answer cited from your own sources.
- **A smart AI tutor.** It walks you through a paper figure by figure, quizzes
  you one question at a time, grades every answer, and brings back what you
  missed until it sticks.
- **Make flashcards, videos and more.** Audio and video overviews, cards,
  quizzes, reports and courses.
- **Any AI model, your own key.** Add your OpenRouter API key and pick
  Claude, GPT, Gemini, DeepSeek or any other model, at OpenRouter's cost.
  ForeverLM adds nothing.

**Only for Mac and iPhone? What about Windows, Linux or Android?**

Yes, Apple only. We chose to make ForeverLM the best it can be on Apple's
devices: your files live in your own iCloud, and ForeverLM keeps track of the
podcasts you listen to on its own.

**Where does my data live?**

In your own iCloud. ForeverLM does not store it.

## Building from source

You need a Mac with Xcode for Swift 6.4 (`.swift-version`).

1. Open `ForeverLMApp/ForeverLM.xcodeproj` and pick the **ForeverLM (macOS)**
   or **ForeverLM (iOS)** scheme. The project file is generated from
   `ForeverLMApp/project.yml` by [XcodeGen](https://github.com/yonaskolb/XcodeGen);
   you only need XcodeGen when you change `project.yml`.
2. Signing is set to ForeverLM's Apple team, and the bundle identifiers, iCloud
   container and App Group are ForeverLM's. To run on your own devices, choose
   your own team and identifiers in Signing & Capabilities (or in
   `project.yml`, then run `xcodegen`). Your build syncs through your own
   iCloud container, not ForeverLM's.
3. A Debug build needs no secrets. `.env.example` lists the build-time OAuth
   clients that YouTube and Google Drive import use; copy it to `.env` and fill
   in your own to try those features.

Model calls go straight from the device to OpenRouter with the learner's own
key, entered in Settings.

**What is not in this repository.** Release and App Store tooling, the
website, and most of the Cloudflare Workers ForeverLM runs on are kept
privately. The app talks to these hosted services:

- `ai.foreverlm.com`, the account service: Sign in with Apple, the trial and the
  paid unlock, and publishing. It accepts sign-ins only from ForeverLM's own
  bundle identifier, so a build under your own identifiers cannot sign in and
  stops at the account screen.
- `plugin.foreverlm.com`, the remote MCP gateway, and the per-Mac MCP relay.
- `app.foreverlm.com`, the setup pages for the Slack, GitHub, Linear and
  Notion connectors.

`workers/shared` holds the MCP tool catalogue the app and the gateway share.

## Contributing

To contribute, see [CONTRIBUTING.md](CONTRIBUTING.md);
to report a vulnerability, see [SECURITY.md](SECURITY.md).

Licensed under [FSL-1.1-ALv2](LICENSE.md).
