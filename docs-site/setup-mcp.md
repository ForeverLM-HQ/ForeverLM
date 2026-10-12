---
layout: doc
title: Connect an AI Assistant
---

# Connect an AI Assistant

Connecting an assistant is part of ForeverLM, with nothing extra to buy: it works in your 7 free days and after you pay ($19 once, no subscription, in **Settings → Billing**), for Claude, ChatGPT, Grok, Gemini, Claude Code and every other MCP client on your account. Once the 7 free days are over and nothing is paid, assistants are told "Your free days of ForeverLM are over. Open ForeverLM on your Mac to continue."

::: tip Most people don't need this
The easiest way to use your sources with AI is to [drag & drop](/drag-and-drop) them directly from Studio. A persistent connection lets an assistant search your full library and run review sessions without dragging files each time.
:::

ForeverLM can host the connection from your private iCloud library, so the Mac app and Web Studio can both stay closed. Open Web Studio once, choose **MCP** in Chat, and complete the separate iCloud authorization for always-on access.

::: warning Hosted MCP privacy
Always-on MCP keeps a revocable iCloud session and an account-scoped cache of synced library metadata, notebooks, Schedule relationships, and saved reviews in ForeverLM-operated Cloudflare storage. Source files remain in iCloud and readable source text is fetched only when a tool requests it. MCP traffic is not end-to-end encrypted from ForeverLM infrastructure.
:::

## Official extensions

- **Claude:** ForeverLM works today as a [custom Claude connector](#claude-custom-connector) on web, desktop, and mobile, and as a [Claude Code plugin](#claude-code-plugin) from its public marketplace. It is **not** in the [Claude Directory](https://claude.ai/directory) or the Claude plugin directory yet; both submissions are in progress. Use the setups below until the listings exist.
- **ChatGPT and Codex:** the official ForeverLM plugin version 1.0.2 was resubmitted to OpenAI on August 31, 2026 and is in `Review`. OpenAI has not issued a public ForeverLM listing URL yet. The plugin will appear in the [ChatGPT Plugins Directory](https://chatgpt.com/plugins) only after approval and ForeverLM's separate publish action.
- **Grok:** ForeverLM works today as a [custom Grok connector](#grok-custom-connector) on web, iOS, and Android. It is **not** listed in the [Grok connector catalog](https://grok.com/connectors) yet. Use the custom setup below until a catalog tile exists.

Until the ChatGPT plugin is public, use the custom setup below. ForeverLM will replace that primary action with OpenAI's canonical listing link after publication; no draft or guessed link is used.

Until ForeverLM appears in the Grok catalog, use the custom Grok connector below. ForeverLM will replace that primary action with the live grok.com/connectors listing after xAI publishes it; no draft or guessed catalog URL is used.

## Claude custom connector

ForeverLM is not in the Claude Directory. Add it as a custom connector instead:

1. In Web Studio, choose **MCP** in Chat and authorize always-on iCloud access. **MCP ✓** confirms it is ready.
2. In Claude on the web, open **Customize → Connectors** (Settings → Connectors redirects there).
3. Choose **Add custom connector**, name it **ForeverLM**, and enter this MCP URL: `https://plugin.foreverlm.com/mcp`. Choose **Continue**.
4. Under **Authentication**, choose **Always required**. Claude's probe labels the server **None · Detected** because the gateway answers MCP discovery before sign-in; every data-bearing tool still needs your account, so keep sign-in required.
5. Under **OAuth client**, choose **No client ID — register one automatically**. ForeverLM registers Claude through Dynamic Client Registration.
6. Choose **Add**, open the new **ForeverLM** entry, choose **Connect**, and complete Sign in with Apple.
7. Ask Claude to check the ForeverLM connection.

Once added on claude.ai, the plugin is also available in Claude Desktop and on Claude mobile under the same account. On a Team or Enterprise plan the entry is shared with the whole organization, so removing it removes it for everyone.

::: info Why the icon can lag behind the brand
Claude draws a custom plugin's icon from Google's favicon cache for the site's root domain (`foreverlm.com`), not from the MCP host. That cache refreshes on Google's schedule, so a recently changed mark can keep showing its predecessor for a while after the site itself is up to date. A directory listing would carry the name and icon directly, which is why one is worth having.
:::

## Claude Code plugin

Claude Code and Cowork can install ForeverLM as a plugin today from its public marketplace, ahead of the directory listing:

```bash
claude plugin marketplace add ForeverLM-HQ/foreverlm-plugins
claude plugin install foreverlm@foreverlm
```

Then run `/mcp` in Claude Code, choose **foreverlm**, and complete Sign in with Apple. The plugin bundles the remote MCP server and four skills: a paper-library migration that moves a [Zotero, Paperpile or Mendeley library](/papers#coming-from-a-reference-manager) into ForeverLM once; a chat export that brings a conversation held with another assistant into ForeverLM as a chat, with the Markdown it produced saved as Pages and its citations linked to your Sources; an AI cost review that reads your AI usage ledger, names the tasks and models behind the spend, and proposes cheaper model settings from the [MCP tools](/mcp-tools#settings) that it applies only once you approve them; and a walkthrough writer that explains a paper, book chapter or article the way a good textbook does, one point at a time with short questions after the points they test, and saves it as the source's walkthrough. Once ForeverLM is published in the Claude plugin directory, `/plugin` will offer it without adding the marketplace.

## ChatGPT custom setup

1. In Web Studio, choose **MCP** in Chat and authorize always-on iCloud access. **MCP ✓** confirms it is ready.
2. In ChatGPT on the web, open **Settings → Apps → Advanced Settings** and enable developer mode.
3. Return to **Settings → Apps**, choose **Create**, and add an app named **ForeverLM** with this MCP URL: `https://plugin.foreverlm.com/mcp`.
4. Choose OAuth authentication, scan the tools, and complete Sign in with Apple.
5. Open a new chat, enable ForeverLM from the tools menu, and ask ChatGPT to check the connection.

ChatGPT plan and workspace permissions determine whether custom MCP apps are available. See [OpenAI's current developer mode requirements](https://help.openai.com/en/articles/12584461-developer-mode-apps-and-full-mcp-connectors-in-chatgpt-beta).

## Grok custom connector

1. In Web Studio, choose **MCP** in Chat and authorize always-on iCloud access. **MCP ✓** confirms it is ready.
2. Open [grok.com/connectors](https://grok.com/connectors).
3. Choose **New Connector**, then **Custom**.
4. Name the plugin **ForeverLM** and enter this MCP URL: `https://plugin.foreverlm.com/mcp`.
5. Complete Sign in with Apple.
6. In a Grok conversation, enable ForeverLM from Plugins and ask Grok to check the connection.

The same plugin is then available in Grok on web, iOS, and Android. If **Custom** is missing, the Grok plan may not include custom MCP plugins. On Grok Business and Enterprise, a team administrator must first add the custom MCP server in the [xAI console](https://console.x.ai).

::: info Catalog listing vs. custom plugin
The Grok catalog does not yet include a ForeverLM tile. A plugin you add yourself is named **ForeverLM** and shows as custom. Keep using that until a catalog listing exists. Do not look for a ForeverLM catalog URL; none has been published.
:::

### Grok Build (CLI)

Grok Build is a separate terminal surface. Adding the server there does not publish ForeverLM in the grok.com catalog.

```bash
grok mcp add --transport http foreverlm "https://plugin.foreverlm.com/mcp"
```

Complete Sign in with Apple on first use, then ask Grok to call `get_mcp_status`.

## Meta Muse custom connector

Muse has no settings screen for custom connectors; it builds one when you ask it to in a chat.

1. In Web Studio, choose **MCP** in Chat and authorize always-on iCloud access. **MCP ✓** confirms it is ready.
2. In the Mac app, open **Settings → MCP** and choose **Copy prompt** on the **Meta Muse** row.
3. Open [muse.ai](https://muse.ai), start a chat, and paste the prompt. It asks Muse to build a Custom Connector named **ForeverLM** for `https://plugin.foreverlm.com/mcp`.
4. Complete Sign in with Apple on the ForeverLM page Muse hands you. The page names Muse as the app you return to.
5. Approve the connector's access when Muse asks, and let Muse save it as a skill so later tasks can use it.

ForeverLM is not in Muse's connector directory, so it runs as a custom connector, which Meta does not review.

## Other assistants

Grok users should follow [Grok custom connector](#grok-custom-connector) instead of copying a prompt.

Any assistant or agent that speaks MCP over HTTP with OAuth can connect on its own: give it `https://plugin.foreverlm.com/mcp`. It registers itself, and you sign in with Apple on a ForeverLM page that names the app you will be sent back to. If ForeverLM does not recognise that app, the page says so; continue only when you started the connection from that app yourself.

For an assistant without its own row, the Mac app's **Settings → MCP** has an **Other assistant** row. Its prompt names no product: it tells the assistant to add the server with its own MCP command, config file, or custom-connector screen, to use OAuth without a client ID, and to say plainly if it cannot reach remote MCP servers.

1. Open Web Studio and choose **MCP** in Chat.
2. Authorize always-on iCloud access and wait for **MCP ✓**.
3. In the Mac app's **Settings → MCP**, select **Copy prompt** on the assistant's row (**ChatGPT** for Codex, or **Gemini**), or on **Other assistant** for any other. Claude Code has [its own plugin](#claude-code-plugin).
4. Paste the prompt into that assistant.
5. Let the assistant complete the setup, then approve the connection when ForeverLM asks.

## Troubleshooting

**Your AI says hosted MCP is not connected:** Open [always-on MCP setup](https://app.foreverlm.com/mcp-connect.html), authorize iCloud, and then retry in a new conversation.

**Setup did not finish:** Return to Web Studio, choose **MCP**, and retry the separate iCloud authorization. The Mac and Web Studio do not need to remain open afterward.
