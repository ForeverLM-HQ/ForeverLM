<p align="center">
  <img src="https://foreverlm.com/assets/app-icon.png" alt="" width="88">
</p>

<h1 align="center">ForeverLM</h1>

<p align="center">
  <strong>Like Gemini Notebook, but for your Mac.</strong><br>
  Chat with your whole library of sources, learn it with a smart AI tutor,<br>
  and make flashcards, audio and video overviews.
</p>

<p align="center">
  <a href="https://foreverlm.com/releases/ForeverLM.dmg"><strong>Download for Mac</strong></a>
  &middot; <a href="https://foreverlm.com">Website</a>
  &middot; <a href="https://docs.foreverlm.com">Docs</a><br>
  Free. MCP: 30 days free, then $19 once. No subscription.
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

## Build from source

You need a Mac with Xcode and the Swift version in [.swift-version](.swift-version).
The app targets macOS 14 and iOS 17.

1. Clone the repository somewhere iCloud does not sync (not `~/Documents` or
   `~/Desktop`).
2. Open `ForeverLMApp/ForeverLM.xcodeproj`. The project file and the package
   pins are tracked, so no generator is needed.
3. Choose the `ForeverLM (macOS)` or `ForeverLM (iOS)` scheme, set your own
   development team under Signing & Capabilities, and run.

A Debug build needs no secrets and no `.env`. Features that need an account
(Sign in with Apple, iCloud sync) need a signed build with your own team and
iCloud container. [.env.example](.env.example) lists what a release build reads.

The rules of the codebase, its layout and how to verify a change are in
[AGENTS.md](AGENTS.md). To contribute, see [CONTRIBUTING.md](CONTRIBUTING.md);
to report a vulnerability, see [SECURITY.md](SECURITY.md).

Licensed under [FSL-1.1-ALv2](LICENSE.md).
