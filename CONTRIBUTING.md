# Contributing to ForeverLM

Thanks for looking. Bug reports, fixes and small improvements are welcome.

## Before you start

- **Report a bug or propose a change in an issue first** when it is more than a
  small fix, so nobody builds something that will not be merged.
- **Security problems do not go in an issue.** See [SECURITY.md](SECURITY.md).
- **Read [AGENTS.md](AGENTS.md).** It holds the rules of this codebase for people
  and coding agents alike: the product's words, storage and migrations, AI
  routing, sync, UI, and how to verify a change.

## Making a change

- Keep a pull request to one change, and say in its description what you ran to
  check it and what is still worth watching ("Verifying changes" in AGENTS.md
  lists the narrowest check for each kind of change).
- Never hand-edit `ForeverLMApp/ForeverLM.xcodeproj/project.pbxproj`; it is
  generated from `ForeverLMApp/project.yml`.
- Never commit credentials, tokens, account identifiers or signing identities.
- **The tree and its history name no person and no company.** Use made-up names
  (Zara Holt, Acme Lab, example.org) in tests and examples.
  `scripts/check-open-tree.sh` checks this; its header shows how to install it
  as `pre-commit` and `commit-msg` hooks.

## License

ForeverLM is licensed under [FSL-1.1-ALv2](LICENSE.md); the packages in
`plugins/` are MIT. By contributing you agree that your contribution is
licensed under the license of the part you change.
