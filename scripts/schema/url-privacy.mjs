// Which live library URLs may be checked in as URL normalizer vectors
// (schema/vectors/url-normalize.json, docs/cloudkit-schema-design.md §4.1).
// A URL is kept out when it points into a private or signed-in place, sits on a
// per-user subdomain, or carries anything that identifies a person, a session or
// an access grant. Once a vector is pushed it stays in git history, so the rule
// errs towards dropping: every branch of the normalizer also has a synthetic case.
// schema/test/generator.test.mjs runs every live case through privacyReason.

/// Name fragments of the library's owner that mark a subdomain as personal,
/// e.g. a personal Cloudflare or chatgpt.site subdomain. They are not written
/// here: set URL_PRIVACY_NAMES (comma-separated, lowercase) when checking live
/// URLs from a real library.
const PERSONAL_NAMES = (process.env.URL_PRIVACY_NAMES ?? "")
  .split(",")
  .map((name) => name.trim().toLowerCase())
  .filter(Boolean);

/// Hosts whose links are private shares, signed-in pages or sign-in flows.
const PRIVATE_HOSTS = [
  "app.read.ai", "read.ai", "zoom.us", "zoom.com", "granola.ai",
  "slack.com", "slack-files.com", "slack-edge.com",
  "docs.google.com", "drive.google.com", "mail.google.com", "scholar.google.com",
  "chatgpt.com", "chat.openai.com", "claude.ai",
  "giftarticle.ft.com", "id.elsevier.com", "idp.nature.com", "idp.springer.com",
  "notion.so", "dropbox.com", "box.com", "onedrive.live.com", "sharepoint.com", "loom.com",
];

/// Hosting where every subdomain is one person's site or app.
const PER_USER_HOST_SUFFIXES = [
  "chatgpt.site", "claude.site", "vercel.app", "netlify.app", "pages.dev", "workers.dev",
  "ngrok.io", "ngrok.app", "ngrok-free.app", "replit.app", "repl.co", "lovable.app",
  "web.app", "firebaseapp.com", "herokuapp.com", "onrender.com", "fly.dev", "streamlit.app",
  "hf.space", "glitch.me", "github.dev", "notion.site",
];

/// Query keys whose value names a reader, a referrer, a session, a click or an
/// access grant, whatever it looks like.
const IDENTIFYING_KEYS = new Set([
  "r", "ref_code", "referrer", "reflink", "triedredirect", "login", "auth", "token", "access_token",
  "sharing_token", "unlocked_article_code", "gift", "giftlink", "smid", "sid", "session", "sessionid",
  "uuid", "user", "selection", "linkid", "trackingid", "tracking_referrer", "twclid", "_sp", "gi",
  "mc_eid", "mc_cid", "_hsenc", "_hsmi", "igshid", "si", "fbclid", "gclid", "ck_subscriber_id",
  "__cf_chl_tk", "share", "st", "postpreview", "freemail", "foreverlm_sync",
  "has_completed_unsubscribed_unlock",
]);

/// Path segments of share, playback and invitation links.
const SHARE_SEGMENTS = new Set(["share", "redeem", "invite", "files-pri", "files-pri-safe", "rec"]);

/// Keys that are not URLs: local and meeting keys are private, ChatGPT library
/// ids name files in someone's account.
const PRIVATE_KEY_PREFIXES = ["/", "file:", "meeting:", "zoom:", "notes:", "urn:chatgpt-library:"];

const UUID = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i;
const TIMESTAMP_HASH = /(^|[^0-9])\d{9,13}[-_.][0-9a-z]{6,}|[0-9a-z]{6,}[-_.]\d{9,13}($|[^0-9])/i;

/// A run of 12 or more letters and digits that mixes both: a hex digest, a
/// click id, a playlist id. Words, slugs, DOIs and PIIs do not mix enough.
function hasTokenRun(text) {
  for (const [run] of text.matchAll(/[A-Za-z0-9]{12,}/g)) {
    const digits = run.replace(/[^0-9]/g, "").length;
    const letters = run.length - digits;
    if (/^[0-9a-f]+$/i.test(run) && digits > 0 && letters > 0) return true;
    if (digits >= 3 && letters >= 3) return true;
  }
  return false;
}

function looksLikeToken(text) {
  return UUID.test(text) || TIMESTAMP_HASH.test(text) || hasTokenRun(text);
}

function hostMatches(host, suffix) {
  return host === suffix || host.endsWith(`.${suffix}`);
}

/// Why `input` may not be checked in, or null when it may.
export function privacyReason(input) {
  const trimmed = input.trim();
  const lower = trimmed.toLowerCase();
  const prefix = PRIVATE_KEY_PREFIXES.find((candidate) => lower.startsWith(candidate));
  if (prefix) return `private key (${prefix})`;
  if (!/^https?:\/\//.test(lower)) return null;

  let url;
  try {
    url = new URL(trimmed);
  } catch {
    return "unparseable URL";
  }
  const host = url.hostname.toLowerCase();
  if (PRIVATE_HOSTS.some((candidate) => hostMatches(host, candidate))) return `private host ${host}`;
  if (PER_USER_HOST_SUFFIXES.some((candidate) => hostMatches(host, candidate))) return `per-user host ${host}`;
  const labels = host.split(".");
  if (labels.some((label) => PERSONAL_NAMES.some((name) => label.includes(name)) || /^[a-z]+-\d{3,}$/.test(label))) return `personal subdomain ${host}`;
  if (url.username || url.password) return "credentials in the URL";

  const segments = url.pathname.split("/").map((segment) => segment.toLowerCase());
  if (segments.some((segment) => SHARE_SEGMENTS.has(segment))) return "share link";
  if (UUID.test(url.pathname)) return "id in the path";

  for (const [key, value] of url.searchParams) {
    if (IDENTIFYING_KEYS.has(key.toLowerCase())) return `query key ${key}`;
    if (looksLikeToken(value)) return `token-like value of ${key}`;
  }
  if (url.hash && looksLikeToken(url.hash)) return "token-like fragment";
  return null;
}
