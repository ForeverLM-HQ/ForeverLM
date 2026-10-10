// JavaScriptCore has ECMAScript and nothing of the web platform: no `URL`,
// no `URLSearchParams`. The renderer reads a link's host to decide whether it
// is a source worth a card (`markdown.ts`), so without a URL parser every
// source came out as a plain link — the one difference between the app's page
// and the site's, measured 2026-09-08. core-js installs the WHATWG URL
// standard's parser when the engine lacks one and leaves a native one alone.
import 'core-js/web/url'
import 'core-js/web/url-search-params'
