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
  A source-available, local-first <strong>alternative to NotebookLM</strong> for Mac, iPhone and iPad:
  an AI research assistant and study app that answers from your own papers, books, PDFs, podcasts and YouTube videos,
  with any AI model you choose.
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

**Is this an alternative to NotebookLM?**

Yes, if you want it on your own Mac and in your own iCloud. Like NotebookLM,
ForeverLM answers from sources you add, with citations, and makes audio and
video overviews, flashcards, quizzes and reports. Unlike it, you pick the AI
model (Claude, GPT, Gemini, DeepSeek, or a free router) with your own
OpenRouter key, your library stays on your devices, it works with Claude,
ChatGPT, Codex and any other MCP client, and the source code is here to read.
The code is under the Functional Source License, which turns into Apache 2.0
two years after each release.

**Where does my data live?**

In your own iCloud. ForeverLM does not store it.

## What is in this repository

The Mac, iPhone and iPad apps, the sync schema, the plugins in `plugins/`, the
user docs in `docs-site/`, and in `workers/shared` the MCP tool catalogue the
app and the gateway share. Release and App Store tooling, the website, and most
of the Cloudflare Workers ForeverLM runs on are kept privately. The app talks
to these hosted services:

- `ai.foreverlm.com`, the account service: Sign in with Apple, the trial and the
  paid unlock, and publishing.
- `plugin.foreverlm.com`, the remote MCP gateway, and the per-Mac MCP relay.
- `app.foreverlm.com`, the setup pages for the Slack, GitHub, Linear and
  Notion connectors.

Model calls go straight from the device to OpenRouter with the learner's own
key, entered in Settings.

## Contributing

To contribute, see [CONTRIBUTING.md](CONTRIBUTING.md);
to report a vulnerability, see [SECURITY.md](SECURITY.md).

Licensed under [FSL-1.1-ALv2](LICENSE.md).

<!-- Keywords: NotebookLM alternative, open source NotebookLM, AI research assistant, chat with PDFs, chat with papers, flashcards from papers, spaced repetition, AI tutor, MCP server, local-first, macOS, iOS, OpenRouter, bring your own key -->
