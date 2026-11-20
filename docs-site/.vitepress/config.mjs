import { defineConfig } from 'vitepress'

export default defineConfig({
  title: 'ForeverLM',
  description: 'Documentation for ForeverLM',
  lang: 'en-US',
  cleanUrls: true,
  sitemap: {
    hostname: 'https://docs.foreverlm.com',
    transformItems: (items) => items.filter((item) => !item.url.startsWith('website/')),
  },

  head: [
    ['link', { rel: 'icon', type: 'image/png', href: '/app-icon.png?v=white' }],
    ['meta', { name: 'theme-color', content: '#6366f1' }],
    ['meta', { name: 'robots', content: 'index, follow, max-image-preview:large' }],
    ['meta', { property: 'og:site_name', content: 'ForeverLM' }],
    ['meta', { property: 'og:type', content: 'website' }],
    ['meta', { name: 'twitter:card', content: 'summary_large_image' }],
  ],

  transformHead({ pageData }) {
    const relativePath = pageData.relativePath
      .replace(/(^|\/)index\.md$/, '$1')
      .replace(/\.md$/, '')
    const canonicalURL = new URL(relativePath, 'https://docs.foreverlm.com/').href
    const title = pageData.title === 'Welcome' ? 'ForeverLM Documentation' : pageData.title
    const description = pageData.description || 'Documentation for ForeverLM'

    return [
      ['link', { rel: 'canonical', href: canonicalURL }],
      ['meta', { property: 'og:title', content: title }],
      ['meta', { property: 'og:description', content: description }],
      ['meta', { property: 'og:url', content: canonicalURL }],
      ['meta', { property: 'og:image', content: 'https://foreverlm.com/assets/home/notebook.jpg?v=20261010' }],
      ['meta', { name: 'twitter:title', content: title }],
      ['meta', { name: 'twitter:description', content: description }],
      ['meta', { name: 'twitter:image', content: 'https://foreverlm.com/assets/home/notebook.jpg?v=20261010' }],
    ]
  },

  themeConfig: {
    logo: '/app-icon.png?v=white',
    siteTitle: 'ForeverLM Docs',

    nav: [
      { text: 'Home', link: 'https://foreverlm.com' },
      { text: 'Support', link: 'https://foreverlm.com/support.html' },
    ],

    sidebar: [
      {
        text: 'Getting Started',
        items: [
          { text: 'Introduction', link: '/index' },
          { text: 'Why Quizzing?', link: '/why-quizzing' },
          { text: 'macOS App', link: '/macos-app' },
          { text: 'Web Library', link: '/web-library' },
        ],
      },
      {
        text: 'Learning Workflow',
        collapsed: false,
        items: [
          { text: 'Studio Overview', link: '/studio' },
          { text: 'Teams', link: '/teams' },
          { text: 'Schedule', link: '/schedule' },
          { text: 'Board', link: '/board' },
          { text: 'Plan', link: '/plan' },
          { text: 'In-App Chat', link: '/in-app-chat' },
          { text: 'Text to Speech', link: '/text-to-speech' },
          { text: 'Voice Mode', link: '/voice-mode' },
          { text: 'AI Providers & Models', link: '/ai-providers' },
        ],
      },
      {
        text: 'Adding Sources',
        collapsed: false,
        items: [
          { text: 'Articles', link: '/articles' },
          { text: 'Books', link: '/books' },
          { text: 'Kindle books', link: '/kindle' },
          { text: 'Courses', link: '/courses' },
          { text: 'Papers', link: '/papers' },
          { text: 'Feeds', link: '/journals' },
          { text: 'Podcasts', link: '/podcasts' },
          { text: 'X Posts', link: '/x-posts' },
          { text: 'Plugins', link: '/external-plugins' },
          { text: 'Build Your Own Plugin', link: '/build-your-own-plugin' },
        ],
      },
      {
        text: 'AI Assistants',
        collapsed: false,
        items: [
          { text: 'Drag & Drop', link: '/drag-and-drop' },
          { text: 'Learning with AI', link: '/learning-with-mcp' },
          { text: 'Connect an AI Assistant', link: '/setup-mcp' },
          { text: 'MCP Tools Reference', link: '/mcp-tools' },
        ],
      },
      {
        text: 'Storage & Privacy',
        collapsed: false,
        items: [
          { text: 'iCloud Storage & Privacy', link: '/icloud-storage' },
        ],
      },
      {
        text: 'Compare',
        collapsed: true,
        items: [
          { text: 'ForeverLM vs Alternatives', link: '/compare/' },
          { text: 'Best NotebookLM Alternatives', link: '/compare/best-notebooklm-alternatives' },
          { text: 'Best PDF Listening Apps', link: '/compare/best-pdf-listening-apps' },
          { text: 'Best AI Research Libraries', link: '/compare/best-ai-research-library-apps' },
          { text: 'vs NotebookLM', link: '/compare/notebooklm' },
          { text: 'vs Heptabase', link: '/compare/heptabase' },
          { text: 'vs Anki', link: '/compare/anki' },
          { text: 'vs RemNote', link: '/compare/remnote' },
          { text: 'vs Quizlet', link: '/compare/quizlet' },
          { text: 'vs Speechify', link: '/compare/speechify' },
          { text: 'vs ElevenReader', link: '/compare/elevenreader' },
          { text: 'vs Readwise Reader', link: '/compare/readwise' },
          { text: 'vs Matter', link: '/compare/matter' },
          { text: 'vs Instapaper', link: '/compare/instapaper' },
          { text: 'vs Raindrop.io', link: '/compare/raindrop' },
          { text: 'vs Glasp', link: '/compare/glasp' },
          { text: 'vs Zotero', link: '/compare/zotero' },
          { text: 'vs Paperpile', link: '/compare/paperpile' },
          { text: 'vs Papers', link: '/compare/papers' },
          { text: 'vs Mendeley', link: '/compare/mendeley' },
          { text: 'vs EndNote', link: '/compare/endnote' },
          { text: 'vs Elicit', link: '/compare/elicit' },
          { text: 'vs SciSpace', link: '/compare/scispace' },
          { text: 'vs Obsidian', link: '/compare/obsidian' },
          { text: 'vs DEVONthink', link: '/compare/devonthink' },
          { text: 'vs LiquidText', link: '/compare/liquidtext' },
          { text: 'vs MarginNote', link: '/compare/marginnote' },
          { text: 'vs Recall', link: '/compare/recall' },
          { text: 'vs Snipd', link: '/compare/snipd' },
          { text: 'vs Paper (paper.ac)', link: '/compare/paper-ac' },
          { text: 'vs Memo', link: '/compare/memo-cards' },
          { text: 'vs Sapience', link: '/compare/sapience' },
          { text: 'vs Gistr', link: '/compare/gistr' },
          { text: 'vs AnythingLLM', link: '/compare/anythingllm' },
        ],
      },
      {
        text: 'Updates',
        collapsed: false,
        items: [
          { text: 'Changelog', link: '/changelog' },
        ],
      },
    ],

    footer: {
      message: 'ForeverLM',
      copyright: '© 2026 · <a href="https://foreverlm.com/privacy.html">Privacy Policy</a>',
    },

    search: {
      provider: 'local',
    },

  },
})
