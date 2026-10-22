/** Speech vocabulary: which five names a meeting sends to the speech engine. */
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { openDb } from "../src/lib/db.js";
import { meetingVocabulary } from "../src/pipeline/vocabulary.js";

const db = openDb(mkdtempSync(path.join(tmpdir(), "vocab-")));
let at = 1;
const meeting = (id: string) =>
  db.prepare("INSERT INTO meetings (id, title, mode, started_at, duration_s) VALUES (?, 'Call', 'discovery', ?, 60)").run(id, at++);
const entity = (id: string, kind: string, label: string) =>
  db.prepare("INSERT INTO entities (id, kind, label, created_at) VALUES (?, ?, ?, 1)").run(id, kind, label);
const mention = (entityId: string, meetingId: string, times = 1, gate = "passed") => {
  for (let i = 0; i < times; i++)
    db.prepare(
      "INSERT INTO entity_mentions (entity_id, meeting_id, surface, source, matcher, score, gate) VALUES (?, ?, ?, 'ngram', 'exact', 1, ?)",
    ).run(entityId, meetingId, `${entityId} ${gate} ${i}`, gate);
};

test("a thread meeting draws its people, then its most-mentioned names, then the thread", () => {
  for (const m of ["t1", "t2", "t3"]) meeting(m);
  db.prepare("INSERT INTO projects (id, name, created_at) VALUES (1, 'Kaleyra Pilot', 1)").run();
  for (const m of ["t1", "t2", "t3"]) db.prepare("INSERT INTO meeting_projects VALUES (?, 1)").run(m);
  db.prepare("INSERT INTO people (id, name, created_at) VALUES (1, 'Rachita Mahajan', 1)").run();
  db.prepare("INSERT INTO project_people (project_id, person_id) VALUES (1, 1)").run();
  entity("person:raj", "person", "Raj Patel");
  entity("person:mei", "person", "Mei Lin");
  entity("topic:exotel", "topic", "Exotel");
  mention("person:mei", "t1", 1);
  mention("person:raj", "t1", 3);
  mention("topic:exotel", "t2", 2);
  assert.deepEqual(meetingVocabulary(db, "t3"), ["Rachita Mahajan", "Raj Patel", "Mei Lin", "Exotel", "Kaleyra Pilot"]);
});

test("placeholders, short and over-long names never make the list; at most five terms", () => {
  meeting("u1");
  db.prepare("INSERT INTO projects (id, name, created_at) VALUES (2, 'Ops', 1)").run();
  db.prepare("INSERT INTO meeting_projects VALUES ('u1', 2)").run();
  const people = ["Speaker 2", "Room 1", "Al", "A name with far too many words in it", "Sharon", "Priyanka", "Gwynne Shotwell", "Taylor", "Jimmy", "Mark Rober"];
  people.forEach((n, i) => {
    db.prepare("INSERT INTO people (id, name, created_at) VALUES (?, ?, 1)").run(100 + i, n);
    db.prepare("INSERT INTO project_people (project_id, person_id) VALUES (2, ?)").run(100 + i);
  });
  const terms = meetingVocabulary(db, "u1");
  assert.equal(terms.length, 5);
  for (const bad of ["Speaker 2", "Room 1", "Al", "A name with far too many words in it", "Ops"]) assert.ok(!terms.includes(bad), bad);
});

test("outside any thread, the people mentioned most in recent meetings are used", () => {
  meeting("r1");
  meeting("r2");
  entity("person:sam", "person", "Sam Altman");
  mention("person:sam", "r1", 2);
  const terms = meetingVocabulary(db, "r2");
  assert.ok(terms.includes("Sam Altman"));
  assert.ok(terms.length <= 5);
});

test("a mention the grounding gate blocked never becomes vocabulary", () => {
  meeting("g1");
  meeting("g2");
  entity("person:ghost", "person", "Ghost Name");
  mention("person:ghost", "g1", 9, "blocked");
  assert.ok(!meetingVocabulary(db, "g2").includes("Ghost Name"));
});
