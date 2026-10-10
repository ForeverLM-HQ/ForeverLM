# ForeverLM

ForeverLM keeps the books, papers, articles, podcasts and videos you learn from,
and quizzes you on them: you explain an idea back in your own words, and the
review tells you what you missed. It runs on the Mac, iPhone and iPad, and it
connects to Claude, ChatGPT and other assistants through MCP.

Documentation for people using the app: [docs.foreverlm.com](https://docs.foreverlm.com).

## What is in this repository

| Path | What it is |
|---|---|
| `ForeverLMApp/` | The Mac and iOS app: library, reader, review, sync, the MCP server |
| `ForeverLMApp/Shared/Portable/` | `ForeverLMCore`, the Foundation-only review and tutor logic, also built for WebAssembly |
| `schema/` | The CloudKit record schema, the merge rules every client shares, and their test vectors |
| `scripts/schema/` | The generator that turns `schema/cloudkit-schema.json` into Swift and JavaScript |
| `workers/shared/` | The public MCP tool contract that assistants and plugins call |
| `docs-site/` | The user documentation at docs.foreverlm.com |
| `plugins/` | The assistant plugin packages (MIT, see `plugins/foreverlm/LICENSE`) |

## Building it yourself

You need Xcode. Open `ForeverLMApp/ForeverLM.xcodeproj` and run the
`ForeverLM (macOS)` scheme, or run `ForeverLMApp/scripts/build_dev.sh`.
`ForeverLMApp/project.yml` is the source of the Xcode project, and
`ForeverLMApp/scripts/sync_project.sh` regenerates it. A debug build needs no
secrets: `.env.example` lists what release builds take.

A build of your own is a smaller app than the one we ship. iCloud sync and the
iOS app need a paid Apple developer account and your own iCloud container. The
hosted services (managed AI, hosted MCP for assistants, the built-in GitHub,
Linear, Notion and Slack plugins, publishing, teams) accept only our signed
builds. What remains is a local library on one Mac, with AI on your own
OpenRouter key.

## License

ForeverLM is source-available under the
[Functional Source License, Version 1.1, ALv2 Future License](LICENSE.md)
(FSL-1.1-ALv2). You may read, run, modify and share it for any purpose except
offering a competing commercial product. Each version becomes available under
the Apache License 2.0 two years after it is released.

The ForeverLM name, logo and app icon are trademarks of ForeverLM and are not
licensed for use by forks. The logos of other companies that ship
with the app are not ours to license. See [NOTICE](NOTICE).
