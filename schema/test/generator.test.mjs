// Tests for the schema source and its generator (docs/cloudkit-schema-design.md §12.1, WP1).
// Run: node --test schema/test/*.test.mjs

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { OUTPUTS, REPO_ROOT, generate, loadSchema, renderCkdb, validateSchema } from "../../scripts/schema/generate.mjs";
import { compareCkdb, normalizeWhitespace, parseCkdb } from "../../scripts/schema/ckdb.mjs";
import { recordName } from "../../scripts/schema/record-name.mjs";
import { privacyReason } from "../../scripts/schema/url-privacy.mjs";
import { buildVectors } from "../../scripts/schema/build-vectors.mjs";

const schema = loadSchema();
const clone = () => structuredClone(schema);

test("generating twice gives the same bytes", () => {
  assert.deepEqual(generate(clone()), generate(clone()));
});

test("the checked-in generated files are current", () => {
  for (const [relativePath, contents] of Object.entries(generate(clone()))) {
    assert.equal(readFileSync(join(REPO_ROOT, relativePath), "utf8"), contents, `${relativePath} is stale; run node scripts/schema/generate.mjs`);
  }
});

test("the schema has the 30 record types of §3.5", () => {
  assert.equal(Object.keys(schema.types).length, 30);
  for (const name of ["ZoneRoot", "Source", "Notebook", "Entry", "Chat", "Exchange", "Card", "Sitting", "Content"]) {
    assert.ok(schema.types[name], name);
  }
});

test("every type has payload, and only Content adds data and asset", () => {
  const ckdb = parseCkdb(renderCkdb(schema));
  for (const name of Object.keys(schema.types)) {
    assert.equal(ckdb[name].fields.payload, "ENCRYPTED BYTES", `${name}.payload`);
    assert.equal(ckdb[name].fields["___recordID"], "REFERENCE QUERYABLE", `${name} ___recordID index`);
    const appFields = Object.keys(ckdb[name].fields).filter((field) => !field.startsWith("___"));
    assert.deepEqual(appFields.sort(), name === "Content" ? ["asset", "data", "payload"] : ["payload"], name);
  }
  assert.equal(ckdb.Content.fields.data, "ENCRYPTED BYTES");
  assert.equal(ckdb.Content.fields.asset, "ASSET");
  assert.deepEqual(ckdb.Users.fields.roles, "LIST<INT64>");
  assert.equal(ckdb.Users.fields["___recordID"], "REFERENCE");
});

test("record names fit in 30 characters for every type", () => {
  const salt = Buffer.alloc(32, 1).toString("base64");
  for (const [name, type] of Object.entries(schema.types)) {
    const longID = "x".repeat(500);
    const computed = recordName(schema, salt, name, longID);
    assert.ok(computed.length <= schema.recordName.maxLength, `${name}: ${computed}`);
    if (type.prefix) assert.match(computed, new RegExp(`^${type.prefix}_[a-z2-7]{26}$`));
    else assert.equal(computed, type.fixedRecordName);
  }
});

test("reserved keys are present on every type and never reused as fields", () => {
  for (const [name, type] of Object.entries(schema.types)) {
    assert.ok(Array.isArray(type.reserved), `${name}.reserved`);
    for (const key of type.reserved) assert.ok(!(key in type.fields), `${name}.${key}`);
  }
  assert.deepEqual(schema.types.Source.reserved, ["signature"]);
});

test("priv-only types never list a space zone, and the codec rules the spec names are encoded", () => {
  const privOnly = Object.entries(schema.types).filter(([, type]) => type.privateOnly).map(([name]) => name).sort();
  assert.deepEqual(privOnly, ["ActivityLog", "Automation", "Card", "Device", "Enrollment", "Goal", "Highlight", "Idea", "Job", "Mark", "NotebookState", "Placement", "Practice", "ReadingState", "Sitting"]);
  for (const name of privOnly) assert.ok(!schema.types[name].zones.includes("Space"), name);
  assert.deepEqual(schema.types.Chat.spaceRule, { field: "kind", allowed: ["chat", "transcript"] });
  // Scores and grading exist only on private chats (D20): exactly these fields carry the flag.
  const privateKindsOnly = Object.entries(schema.types)
    .flatMap(([name, type]) => Object.entries(type.fields).filter(([, field]) => field.privateKindsOnly).map(([fieldName]) => `${name}.${fieldName}`))
    .sort();
  assert.deepEqual(privateKindsOnly, ["Chat.overallScore", "Exchange.grading", "Exchange.score"]);
  assert.deepEqual(schema.types.Card.fields.status.terminalValues, ["retired"]);
  assert.equal(schema.types.Content.immutable, true);
  for (const [name, type] of Object.entries(schema.types)) {
    for (const [fieldName, field] of Object.entries(type.fields)) {
      if (field.memberLocal) assert.ok(type.privateOnly, `${name}.${fieldName} is member-local on a shareable type`);
    }
  }
  assert.ok(Object.values(schema.types.Exchange.fields).every((field) => field.policy === "S"));
});

test("the .ckdb lists the types sorted by name, Users included", () => {
  const names = Object.keys(parseCkdb(renderCkdb(schema)));
  assert.deepEqual(names, [...names].sort());
  assert.ok(names.includes("Users"));
  assert.equal(names.length, 31);
});

test("the .ckdb compares equal to itself and reports a missing field", () => {
  const text = renderCkdb(schema);
  assert.deepEqual(compareCkdb(text, text), { missing: [], changed: [], extra: [] });
  const withoutAsset = text.replace(/\n\s+asset\s+ASSET,/, "");
  assert.deepEqual(compareCkdb(text, withoutAsset).missing, ["field Content.asset (ASSET)"]);
  assert.equal(normalizeWhitespace(text.replace(/ {2,}/g, " ")), normalizeWhitespace(text));
});

test("validation refuses the mistakes the generator guards against", () => {
  const cases = [
    ["an unknown policy letter", (s) => { s.types.Notebook.fields.title.policy = "Q"; }, /unknown policy Q/],
    ["a repeated prefix", (s) => { s.types.Goal.prefix = "nb"; }, /prefix nb is already Notebook's/],
    ["a priv-only type in a space", (s) => { s.types.Mark.zones.push("Space"); }, /priv-only type cannot list the Space zone/],
    ["a set merged by first writer", (s) => { s.types.Source.fields.workKeys.policy = "S"; }, /sets merge per element/],
    ["a reserved key used as a field", (s) => { s.types.Source.fields.signature = { ...s.types.Source.fields.title }; }, /reserved key signature is also a field/],
    ["an unknown enum", (s) => { s.types.Source.fields.type.enum = "Nope"; }, /unknown enum Nope/],
    ["a ref to an unknown type", (s) => { s.types.Goal.fields.notebookID.ref = "Notebok"; }, /unknown type Notebok/],
    ["a mutable field on an immutable type", (s) => { s.types.Content.fields.role.policy = "L"; }, /immutable type has only S fields/],
    ["a field without required", (s) => { delete s.types.Notebook.fields.title.required; }, /required must be/],
    ["a T field that is not a FileRef", (s) => { s.types.Notebook.fields.title.policy = "T"; }, /T field is a pointer/],
    ["a member-local field on a shareable type", (s) => { s.types.Source.fields.title.memberLocal = true; }, /member-local field may only sit on a priv-only type/],
    ["a private-kinds-only field outside Chat and Exchange", (s) => { s.types.Notebook.fields.title.privateKindsOnly = true; }, /privateKindsOnly applies only to Chat and Exchange fields/],
    ["privateKindsOnly set to false", (s) => { s.types.Chat.fields.title.privateKindsOnly = false; }, /privateKindsOnly is true or absent/],
    ["terminal values on a first-writer field", (s) => { s.types.Card.fields.status.policy = "S"; }, /terminal values apply to a scalar last-writer field/],
    ["spill: false on a field that is not a plain string", (s) => { s.types.Source.fields.addedAt.spill = false; }, /applies only to a plain string field/],
    ["a lost-first-write hook on a last-writer field", (s) => { s.types.Card.onServerFirstLoss = { draft: "splitKeptCard" }; }, /not an S field/],
    ["an envelope without saltID", (s) => { s.envelope.keys = s.envelope.keys.filter((key) => key !== "saltID"); }, /envelope.keys must list saltID/],
    ["a setting of an unknown value type", (s) => { s.settings.keys["uiZoomStep"].type = "float"; }, /type must be one of SettingValueType/],
    ["an exact setting key under a family's prefix", (s) => { s.settings.keys["aiTask.chat.prompt"] = { type: "string", doc: "x" }; }, /starts with the prefix aiTask\./],
    ["set_app_setting without a setting id", (s) => { delete s.settings.keys["images.model"].mcp.setting; }, /mcp.setting goes with set_app_setting/],
    ["a retired key with a route that writes it", (s) => { s.settings.keys["stt_provider"].mcp = { tool: "set_app_setting", setting: "x" }; }, /a retired key is never written/],
    ["a record move to a field the type lacks", (s) => { s.settings.records["studio.projectOrder"] = "NotebookState.order"; }, /NotebookState has no field order/],
    ["a record move written as an object without origin spec", (s) => { s.settings.records["studio.projectOrder"] = { record: "NotebookState.sidebarKey" }; }, /carries origin "spec"/],
    ["a prefix both left out and a family", (s) => { s.settings.families["notebookCollection."] = s.settings.families["follow."]; }, /a prefix is listed twice/],
    ["a left-out pattern outside its prefix", (s) => { s.settings.leftOut["notebookCollection."].pattern = "collection.<id>"; }, /the pattern starts with its prefix/],
    ["an exact key under a left-out prefix", (s) => { s.settings.keys["notebookCollection.nbc-1"] = { type: "string", doc: "x" }; }, /starts with the prefix notebookCollection\./],
    ["a priv-only type placed outside Library", (s) => { s.types.Mark.home = { rule: "current", privateZone: "Library" }; }, /priv-only types, and only they, live in library/],
    ["an unknown placement rule", (s) => { s.types.Task.home = { rule: "space" }; }, /rule must be one of/],
    ["a parent the field does not refer to", (s) => { s.types.Lesson.home.parent = "Notebook"; }, /parent must be the one type courseID refers to/],
    ["a container kind with no parent type", (s) => { delete s.types.Entry.home.parents.playlist; }, /parents must name a type for every value of EntryContainerKind/],
    ["a private zone the type never uses", (s) => { s.types.Source.home.privateZone = "Library"; }, /privateZone Library is not one of the type's zones/],
  ];
  for (const [label, mutate, pattern] of cases) {
    const broken = clone();
    mutate(broken);
    assert.throws(() => validateSchema(broken), pattern, label);
  }
});

test("the JS module matches the schema", async () => {
  const module = await import(join(REPO_ROOT, OUTPUTS.js));
  assert.equal(module.SCHEMA_REVISION, schema.schemaRevision);
  assert.equal(module.CONTAINER, schema.container);
  assert.deepEqual([...module.TYPE_NAMES], Object.keys(schema.types));
  assert.equal(module.TYPE_BY_PREFIX.nb, "Notebook");
  assert.equal(module.TYPES.NotebookState.fields.excluded.keyRef[0], "Source");
  assert.deepEqual([...module.TYPES.Entry.fields.containerID.ref], ["Notebook", "Goal", "Lesson", "Collection"]);
  assert.ok(Object.isFrozen(module.TYPES.Source.fields.title));
  assert.ok(module.ENVELOPE_KEYS.includes("saltID"));
  assert.equal(module.SPILL_MARKER_KEY, "$file");
  assert.equal(module.TYPES.Card.onServerFirstLoss.kept, "splitKeptCard");
  assert.equal(module.TYPES.Exchange.fields.question.spills, true);
  // A set of strings never spills: its elements are keys under their own stamps (§3.2 rule 8).
  assert.equal(module.TYPES.ReadingState.fields.discussedIdeaKeys.spills, undefined);
  assert.equal(module.TYPES.NotebookState.fields.collections.spills, undefined);
  assert.equal(module.TYPES.Setting.fields.key.spills, undefined);
  assert.equal(module.TYPES.Chat.fields.kind.spills, undefined);
  assert.equal(module.TYPES.NotebookState.fields.courseOrder.memberLocal, true);
  assert.equal(module.TYPES.Exchange.fields.grading.privateKindsOnly, true);
  assert.equal(module.TYPES.Chat.fields.overallScore.privateKindsOnly, true);
  assert.equal(module.TYPES.Chat.fields.briefing.privateKindsOnly, undefined);
  assert.equal(module.LIMITS.payloadMaxInflatedBytes, 16 * 1024 * 1024);
  // Placement is data (§4.4): every priv-only type lives in Library, the rest name their rule.
  for (const name of module.TYPE_NAMES) {
    assert.equal(module.TYPES[name].home.rule === "library", module.TYPES[name].privateOnly, name);
  }
  assert.deepEqual(module.TYPES.Source.home, { rule: "current", privateZone: "Catalog" });
  assert.equal(module.TYPES.Entry.home.parents.playlist, "Collection");
  assert.equal(module.TYPES.Exchange.home.parent, "Chat");
  assert.deepEqual([...module.TYPES.Artifact.home.personalIDPrefixes], ["draft:"]);
  assert.equal(module.TYPES.Content.home.rule, "owner");
  assert.ok(module.STAMP_PATTERN.test("L1759400000123.0001.k3f7ab2q"));
  assert.ok(!module.STAMP_PATTERN.test("L1759400000123.0001.k3f9ab2q"));
  // The website serves this module, and no served script carries an em dash.
  assert.ok(!readFileSync(join(REPO_ROOT, OUTPUTS.js), "utf8").includes("—"));
});

test("the settings catalog gives every key a value type, a scope and the route a chat sets it by", () => {
  const catalog = JSON.parse(readFileSync(join(REPO_ROOT, OUTPUTS.settings), "utf8"));
  assert.equal(catalog.catalog, "settings");
  assert.deepEqual(catalog.valueTypes, schema.enums.SettingValueType.values);
  assert.ok(Object.keys(catalog.keys).length > 100);
  const rows = [...Object.values(catalog.keys), ...Object.values(catalog.families).flat()];
  for (const row of rows) {
    assert.ok(catalog.valueTypes.includes(row.type), JSON.stringify(row));
    assert.ok(row.scope.length > 0 && row.scope.every((scope) => scope in catalog.scopes), JSON.stringify(row));
    assert.ok(row.mcp === null || typeof row.mcp.tool === "string", JSON.stringify(row));
  }
  assert.deepEqual(catalog.keys["memory.new_cards_per_day"].range, { min: 1, max: 100 });
  assert.deepEqual(catalog.keys["memory.new_cards_per_day"].mcp, { tool: "set_memory_review_settings", argument: "new_cards_per_day" });
  assert.deepEqual(catalog.keys["images.model"].mcp, { tool: "set_app_setting", setting: "images.model" });
  assert.equal(catalog.families["aiTask."][0].pattern, "aiTask.<task>.prompt");
  assert.deepEqual(catalog.families["follow."][0].scope, ["space"]);
  assert.deepEqual(catalog.records["studio.projectOrder"], { match: "key", record: "NotebookState", field: "sidebarKey" });
  // The Courses tab's one order is an account Setting, not a notebook's (spec revision 9).
  assert.equal(catalog.keys["studio.courseOrder"].type, "array");
  assert.deepEqual(catalog.records["podcasts.blockedShows"], { match: "key", record: "Mark", markKind: "importBlocked" });
  assert.deepEqual(catalog.records["meetingFolder.image."], { match: "prefix", record: "Collection", field: "files", key: "icon" });
  // The domain prefixes of §10 are records, not Settings; a Notebook Collection's name stays a
  // Setting that only its own writers set, so the catalog leaves it out by name (§3.5.3).
  assert.deepEqual(catalog.records["notebook.collections."], { match: "prefix", record: "NotebookState", field: "collections" });
  assert.deepEqual(catalog.records["notebook.chatContextNotebooks."], { match: "prefix", record: "NotebookState", field: "contextNotebooks", origin: "spec" });
  assert.deepEqual(Object.keys(catalog.leftOut).sort(), ["aiSeeded.task.", "chat.pinned.", "images.notebookCoverBackfill.", "map.layout.", "notebook.naming.", "notebook.questions.", "notebookCollection.", "page.parent.", "page.pinned.", "page.space.", "pageSpace.", "pageSpaceTrash.", "spaceList.", "spaceListItem.", "studio.workspaceView."]);
  assert.equal(catalog.leftOut["notebook.questions."].type, "string");
  assert.equal(catalog.leftOut["notebookCollection."].type, "string");
  // A space of pages' name and a page's one space (PageSpaces) are their writers' Settings too.
  assert.equal(catalog.leftOut["pageSpace."].type, "string");
  assert.equal(catalog.leftOut["page.space."].type, "string");
  // A pinned page's moment (PagePins) is the same kind of row.
  assert.equal(catalog.leftOut["page.pinned."].type, "string");
  // A nested page's parent (PageParents) is another: one Setting per child, never a field of the Doc.
  assert.equal(catalog.leftOut["page.parent."].type, "string");
  // The notebook cover Setting is a key (D53); its backfill's marker is a dict that only the backfill writes, so it is left out.
  assert.equal(catalog.keys["images.drawNotebookCovers.automatic"].type, "bool");
  assert.equal(catalog.leftOut["images.notebookCoverBackfill."].type, "dict");
  assert.equal(catalog.leftOut["aiSeeded.task."].type, "bool");
  assert.ok(Object.keys(catalog.keys).every((key) => !key.startsWith("images.notebookCoverBackfill.")));
  for (const prefix of ["notebookCollection.", "notebook.collections.", "notebook.chatContextNotebooks."]) {
    assert.ok(!(prefix in catalog.families), prefix);
    assert.ok(Object.keys(catalog.keys).every((key) => !key.startsWith(prefix)), prefix);
  }
  assert.equal(catalog.aiTasks.ids[0], "chat");
  // No exact key is also a family prefix's or a record's, so a key has one entry.
  for (const key of Object.keys(catalog.keys)) {
    assert.ok(!(key in catalog.records), key);
    for (const prefix of [...Object.keys(catalog.families), ...Object.keys(catalog.records).filter((name) => name.endsWith(".")), ...Object.keys(catalog.leftOut)]) {
      assert.ok(!key.startsWith(prefix), `${key} starts with ${prefix}`);
    }
  }
});

test("every vector file names its spec and carries a list of cases", () => {
  const directory = join(REPO_ROOT, "schema/vectors");
  const files = readdirSync(directory).filter((file) => file.endsWith(".json")).sort();
  assert.deepEqual(files, ["card-schedule.json", "chat-kind.json", "chat-ticks.json", "envelope.json", "fractional-index.json", "locator.json", "merge.json", "naming.json", "placement.json", "replica-audit.json", "resolve.json", "stamp-clock.json", "text-merge.json", "url-normalize.json", "work-key.json"]);
  for (const file of files) {
    const vectors = JSON.parse(readFileSync(join(directory, file), "utf8"));
    assert.equal(vectors.vectors, file.replace(/\.json$/, ""), file);
    assert.equal(typeof vectors.spec, "string", file);
    assert.equal(typeof vectors.format, "string", file);
    assert.ok(Array.isArray(vectors.cases), file);
  }
});

test("the computed vector files are what build-vectors.mjs makes from its reference implementations", async () => {
  for (const { path, text } of await buildVectors()) {
    assert.equal(readFileSync(path, "utf8"), text, `${path} is stale; run node scripts/schema/build-vectors.mjs`);
  }
  const merge = JSON.parse(readFileSync(join(REPO_ROOT, "schema/vectors/merge.json"), "utf8"));
  assert.ok(merge.cases.length >= 200, "§6.2 asks for 200 merge cases or more");
});

test("the naming vectors agree with the tools' record names", () => {
  const vectors = JSON.parse(readFileSync(join(REPO_ROOT, "schema/vectors/naming.json"), "utf8"));
  assert.ok(vectors.cases.length > 30);
  for (const vector of vectors.cases) {
    assert.equal(recordName(schema, vectors.salts[vector.salt], vector.type, vector.id), vector.recordName, `${vector.type} ${vector.id}`);
  }
});

test("no live URL vector is a private link or carries a token, and every stand-in is one the filter drops", () => {
  const vectors = JSON.parse(readFileSync(join(REPO_ROOT, "schema/vectors/url-normalize.json"), "utf8"));
  const live = vectors.cases.filter((vector) => vector.origin === "live");
  const standIns = vectors.cases.filter((vector) => vector.origin === "stand-in");
  assert.deepEqual(live.map((vector) => [vector.input, privacyReason(vector.input)]).filter(([, reason]) => reason), []);
  assert.ok(standIns.length > 0);
  for (const vector of standIns) assert.ok(privacyReason(vector.input), vector.input);
});
