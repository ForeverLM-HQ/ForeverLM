---
layout: doc
title: Drag & Drop
---

# Drag & Drop

The primary way to use your sources with Claude, ChatGPT, Gemini, Grok, or Edison Scientific. Your library is your content folder: add sources, then drag them straight into any AI chat.

## How It Works

1. **Find the source** in the Library, or open it in the Reader.

2. **Drag it** into your Claude, ChatGPT, Gemini, Grok, or Edison Scientific chat window: its row in the Library, or the title of the source open in the Reader. It arrives in the chat as a file.

That's it. No accounts, no configuration, no extra tools.

## Tips

- Each drag carries one source: drag each source you want the chat to read.
- A paper with its PDF arrives as the PDF. Articles, podcasts and other sources with text arrive as text files, and a source with neither arrives as a link to its web page.

## Optional: Persistent Access

If you'd rather not drag sources into every conversation, you can [connect an AI assistant](/setup-mcp). This lets Claude, Codex, Gemini, or Grok search your entire library, read any source on demand, and run review sessions — all without dragging.

ForeverLM provides a hosted Cloudflare relay for MCP. MCP requests and responses pass through ForeverLM-operated Cloudflare infrastructure in transit and are not logged or stored there.

| | Drag & Drop | MCP Server |
|---|---|---|
| **Setup** | None | Copy the matching assistant prompt |
| **Sources** | What you drag in | Entire library |
| **Interaction** | Upload files into chat | AI calls tools directly |
| **Best for** | Most conversations | Power users who want hands-free access |
