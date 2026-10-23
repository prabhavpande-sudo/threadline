/** Speaker names from meeting-app hints: the voting rules, no network. */
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { openDb } from "../src/lib/db.js";
import { nameSpeakersFromHints } from "../src/pipeline/speaker-names.js";

const db = openDb(mkdtempSync(path.join(tmpdir(), "names-")));

function meeting(id: string, turns: [speaker: string, at: number, dur: number][], hints: [at: number, name: string][]) {
  db.prepare("INSERT INTO meetings (id, title, mode, started_at, duration_s) VALUES (?, 'Call', 'discovery', 1, 120)").run(id);
  const u = db.prepare("INSERT INTO utterances (meeting_id, idx, speaker, speaker_role, text, offset_s, duration_s) VALUES (?, ?, ?, 'customer', 'words', ?, ?)");
  turns.forEach(([s, at, dur], i) => u.run(id, i, s, at, dur));
  const h = db.prepare("INSERT INTO speaker_hints (meeting_id, offset_s, name, app) VALUES (?, ?, ?, 'zoom')");
  for (const [at, name] of hints) h.run(id, at, name);
}
const speakers = (id: string) =>
  (db.prepare("SELECT DISTINCT speaker FROM utterances WHERE meeting_id = ? ORDER BY speaker").all(id) as { speaker: string }[]).map((r) => r.speaker);

test("each voice takes the name the app showed while it spoke", () => {
  meeting("sn1", [["Speaker 1", 0, 10], ["Speaker 2", 10, 10], ["Speaker 1", 20, 10]],
    [[1, "Sharon"], [4, "Sharon"], [8, "Sharon"], [11, "Raj"], [14, "Raj"], [18, "Raj"], [22, "Sharon"]]);
  const named = nameSpeakersFromHints(db, "sn1");
  assert.deepEqual(named.map((n) => [n.from, n.to]).sort(), [["Speaker 1", "Sharon"], ["Speaker 2", "Raj"]]);
  assert.deepEqual(speakers("sn1"), ["Raj", "Sharon"]);
  assert.ok(db.prepare("SELECT 1 FROM people WHERE name = 'Sharon'").get(), "named voices become people");
});

test("too few votes or no clear majority leaves the placeholder", () => {
  meeting("sn2", [["Speaker 1", 0, 10], ["Speaker 2", 10, 10]],
    [[1, "Sharon"], [3, "Sharon"], [11, "Raj"], [13, "Mei"], [15, "Raj"], [17, "Mei"]]);
  assert.deepEqual(nameSpeakersFromHints(db, "sn2"), []);
  assert.deepEqual(speakers("sn2"), ["Speaker 1", "Speaker 2"]);
});

test("a name goes to one voice only — the one with the strongest evidence", () => {
  meeting("sn3", [["Speaker 1", 0, 10], ["Speaker 2", 10, 10]],
    [[1, "Sharon"], [3, "Sharon"], [5, "Sharon"], [7, "Sharon"], [11, "Sharon"], [13, "Sharon"], [15, "Sharon"]]);
  const named = nameSpeakersFromHints(db, "sn3");
  assert.deepEqual(named.map((n) => [n.from, n.to]), [["Speaker 1", "Sharon"]]);
  assert.deepEqual(speakers("sn3"), ["Sharon", "Speaker 2"]);
});

test("hints in the owner's own name never name a call voice", () => {
  db.prepare("INSERT INTO meta (key, value) VALUES ('profile', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value")
    .run(JSON.stringify({ first_name: "Prabhav", last_name: "Pande" }));
  // The owner backchannels over Speaker 1's turn, so Meet marks the owner's tile.
  meeting("sn5", [["Speaker 1", 0, 20]],
    [[1, "Prabhav Pande"], [3, "Prabhav Pande"], [5, "Prabhav Pande"], [7, "Prabhav Pande"], [12, "Deepan"], [14, "Deepan"], [16, "Deepan"]]);
  const named = nameSpeakersFromHints(db, "sn5");
  assert.deepEqual(named.map((n) => [n.from, n.to]), [["Speaker 1", "Deepan"]]);
  db.prepare("DELETE FROM meta WHERE key = 'profile'").run();
});

test("room voices and hints that fall between turns are ignored", () => {
  meeting("sn4", [["Room 1", 0, 10], ["Speaker 1", 30, 5]],
    [[1, "Sharon"], [3, "Sharon"], [5, "Sharon"], [20, "Raj"], [21, "Raj"], [22, "Raj"]]);
  assert.deepEqual(nameSpeakersFromHints(db, "sn4"), []);
  assert.deepEqual(speakers("sn4"), ["Room 1", "Speaker 1"]);
});
