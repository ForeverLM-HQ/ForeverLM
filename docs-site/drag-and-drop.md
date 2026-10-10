---
layout: doc
title: Drag & Drop
---

# Drag & Drop

The primary way to use your sources with Claude, ChatGPT, Gemini, Grok, or Edison Scientific. Studio is your content folder — add sources, then drag them straight into any AI chat.

## How It Works

1. **Add sources to the context tray** at the bottom of the Studio sidebar. Either drag them in, or right-click and choose **Add to Context**.

2. **Drag the Export button** from the tray directly into your Claude, ChatGPT, Gemini, Grok, or Edison Scientific chat window. All sources in the tray are sent at once as files.

That's it. No accounts, no configuration, no extra tools.

## Tips

- You can add multiple sources to the tray — drag them in one at a time, or select several (shift-click / cmd-click) and right-click to add them all.
- Click the **x** on a chip to remove a single source from the tray, or **Clear** to remove all.
- Papers with local PDFs are exported as PDF files. Articles and podcasts are exported as text files.

## Optional: Persistent Access

If you'd rather not drag sources into every conversation, you can [connect an AI assistant](/setup-mcp). This lets Claude, Codex, Gemini, or Grok search your entire library, read any source on demand, and run review sessions — all without dragging.

ForeverLM provides a hosted Cloudflare relay for MCP. MCP requests and responses pass through ForeverLM-operated Cloudflare infrastructure in transit and are not logged or stored there.

| | Drag & Drop | MCP Server |
|---|---|---|
| **Setup** | None | Copy the matching assistant prompt |
| **Sources** | What you drag in | Entire library |
| **Interaction** | Upload files into chat | AI calls tools directly |
| **Best for** | Most conversations | Power users who want hands-free access |
