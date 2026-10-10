#!/bin/zsh
set -euo pipefail

# Seeds ForeverLM Dev from the daily-use production library without stopping
# ForeverLM. APFS clone copies are initially space-efficient; SQLite's online
# backup API supplies a transactionally consistent knowledge.db even while the
# production app remains open.
#
# The production library's older files still sit in the personal team's
# retired iCloud container, iCloud~com~foreverlm/Documents/ForeverLM, which the
# apps read by path and nothing writes any more (the company team, XXXXXXXXXX,
# since 2026-10-09). The seed only reads that folder: its files are copied into
# ForeverLM Dev's own local content root, Application Support/ForeverLM Dev/
# Content, where the Dev app writes content, and nothing is ever written to or
# removed from the old container.

production_support="$HOME/Library/Application Support/ForeverLM"
development_support="$HOME/Library/Application Support/ForeverLM Dev"
development_content="$development_support/Content"
production_ubiquity="$HOME/Library/Mobile Documents/iCloud~com~foreverlm/Documents/ForeverLM"
production_cloud_docs="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Documents/ForeverLM"
development_cloud_docs="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Documents/ForeverLM Dev"

copy_icloud_documents() {
    if [[ -d "$production_ubiquity" ]]; then
        /bin/mkdir -p "$development_content"
        # CloudDocs may need to download placeholders. rsync is intentionally
        # resumable so an interrupted multi-gigabyte audio copy starts where it
        # left off rather than replacing the finished Dev library. A file the
        # production Content folder already gave Dev wins, as production's own
        # local root wins over the old container when it resolves a path.
        /usr/bin/rsync -a --ignore-existing "$production_ubiquity/" "$development_content/"
    fi

    if [[ -d "$production_cloud_docs" ]]; then
        /bin/mkdir -p "$development_cloud_docs"
        /usr/bin/rsync -a "$production_cloud_docs/" "$development_cloud_docs/"
    fi
}

if [[ "${1:-}" == "--resume-icloud" ]]; then
    if [[ ! -f "$development_support/.appdata/knowledge.db" ]]; then
        print -u2 "ForeverLM Dev has no seeded database; run the one-time seed without --resume-icloud first."
        exit 1
    fi
    copy_icloud_documents
    print "ForeverLM Dev iCloud document copy is complete."
    exit 0
fi

if [[ ! -f "$production_support/.appdata/knowledge.db" ]]; then
    print -u2 "ForeverLM production database was not found at $production_support/.appdata/knowledge.db"
    exit 1
fi

if [[ -e "$development_support" || -e "$development_cloud_docs" ]]; then
    print -u2 "ForeverLM Dev already has data. This seed is intentionally one-time and will not overwrite it."
    exit 1
fi

staging_parent="$(mktemp -d "$HOME/Library/Application Support/ForeverLM-Dev-Seed.XXXXXX")"
cleanup() {
    if [[ -d "$staging_parent" ]]; then
        rm -rf "$staging_parent"
    fi
}
trap cleanup EXIT INT TERM

staged_support="$staging_parent/ForeverLM Dev"
/bin/cp -cR "$production_support" "$staged_support"

staged_database="$staged_support/.appdata/knowledge.db.seed"
/usr/bin/sqlite3 "$production_support/.appdata/knowledge.db" ".backup '$staged_database'"
/bin/rm -f \
    "$staged_support/.appdata/knowledge.db" \
    "$staged_support/.appdata/knowledge.db-wal" \
    "$staged_support/.appdata/knowledge.db-shm"
/bin/mv "$staged_database" "$staged_support/.appdata/knowledge.db"

/bin/mv "$staged_support" "$development_support"

copy_icloud_documents

trap - EXIT INT TERM
/bin/rmdir "$staging_parent"

print "ForeverLM Dev was seeded successfully."
print "Production:  $production_support"
print "Development: $development_support"
