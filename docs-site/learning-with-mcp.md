---
layout: doc
title: Learning with MCP
---

# Learning with AI

Once your sources are in Studio, you can use AI assistants to actively learn from them — either by [dragging sources into a chat](/drag-and-drop) or through a persistent [MCP connection](/setup-mcp). This page covers the main workflows: exploring sources, review, and Socratic dialogue.

## Exploring your sources

The simplest starting point: ask your AI assistant what you've been reading.

**Example prompts:**
- *"List my sources and give me an overview of what I've been reading lately."*
- *"Search my sources for anything related to attention mechanisms."*
- *"Read my latest paper and give me a one-paragraph summary."*
- *"Compare these two papers — what do they agree on, and where do they diverge?"*

Ask about "the notebook I have open" and your AI uses `get_app_context`, which names the notebook in each ForeverLM window, frontmost first, and reads the frontmost one's sources. Or let it search with `search_sources_semantic` to find relevant sources by topic, or `search_sources_keyword` to sweep the library for every mention of an exact word.

## Review sessions

The idea is simple: explain a concept from scratch, as if teaching it. If you can't explain it simply, you don't understand it yet.

ForeverLM's MCP tools support structured review sessions that track your understanding over time.

### Starting a session

Ask your AI assistant to quiz you:

- *"Start a review session on CRISPR-Cas9 mechanisms."*
- *"Test my understanding of transformer self-attention."*
- *"Quiz me on the paper I just read about partial reprogramming."*

The AI calls `start_review_session`, which searches your source library for relevant content and returns it as context. The AI then asks you to explain the concept.

### During the session

The AI asks questions, you explain, and the AI evaluates your understanding:

1. **You explain** the concept in your own words
2. **The AI evaluates** — checking for accuracy, depth, and whether you addressed mechanisms vs. just surface-level facts
3. **Follow-up probes** — the AI asks targeted questions about gaps or imprecise parts of your explanation
4. **Repeat** until the topic is thoroughly covered

The AI evaluates your answers directly in the chat.

### Ending a session

When you're done, the AI calls `end_review_session` with an overall score, summary, and exported chat transcript. You can review past sessions later with `get_review_sessions` and `get_review_session_transcript` to track your understanding progression.

### Example session

> **You:** Quiz me on oxidative phosphorylation.
>
> **AI:** *[starts a review session, loads your biochemistry sources]*
> Explain the chemiosmotic theory — how does the proton gradient drive ATP synthesis?
>
> **You:** So the electron transport chain pumps protons across the inner mitochondrial membrane, creating a gradient. Then ATP synthase uses that gradient to generate ATP.
>
> **AI:** Good start — you've got the high-level flow right. But let me probe deeper: *why* does the proton gradient specifically drive ATP synthase rotation? What's the physical mechanism that converts a concentration gradient into mechanical work?
>
> **You:** The protons flow through a channel in ATP synthase, and the flow causes a rotor subunit to spin. Each rotation mechanically changes the conformation of the catalytic sites, forcing ADP and phosphate together.
>
> **AI:** Excellent — you've nailed the rotary catalysis mechanism. Score: 0.9. One more: what happens to ATP production if you add an uncoupling agent like DNP?

## Socratic dialogue

Beyond structured review sessions, you can have free-form Socratic dialogue with your AI about any source:

- *"I just read this paper on diffusion models. Challenge my understanding — ask me hard questions."*
- *"I think I understand how RLHF works, but test me. Don't go easy."*
- *"Play devil's advocate on the claims in this source about longevity interventions."*

The AI has full access to your source text, so it can cite specific passages, catch misunderstandings, and push you to think more precisely.

## Tips

- **Select sources first.** Before starting a session, select the relevant sources in Studio so the AI has the full text as context.
- **Be specific about topics.** "Quiz me on attention" is less effective than "Quiz me on multi-head attention scaling and why we divide by sqrt(d_k)."
- **Don't just answer — explain.** Explaining works because it forces you to articulate mechanisms, not just recall facts.
- **Review past sessions.** Ask *"Show me my past review sessions on [topic]"* to see how your understanding has progressed.
- **Use across sources.** The best learning happens when you connect ideas: *"I've read papers on both CRISPR and base editing — quiz me on the differences in their mechanisms."*
