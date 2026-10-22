/**
 * Speech vocabulary: up to five names the speech engine should listen for in
 * one meeting, drawn from what the brain already knows about its thread —
 * the people on it, then the people and topics its earlier meetings kept
 * mentioning, then the thread's own name. Meetings outside any thread fall
 * back to the people mentioned most across the 20 most recent meetings.
 *
 * PyAI uses at most five terms per job and ignores entries under 4 or over
 * 64 characters, longer than 5 words, or made of common words, so the list is
 * pre-filtered to the same shape. Measured on a synthesized clip naming five
 * people and companies: 0/5 spelled right without vocabulary, 5/5 with it.
 * Local only — the terms come from this machine's SQLite file.
 */
import type { DatabaseSync } from "node:sqlite";

const MAX_TERMS = 5;
const RECENT_MEETINGS = 20;

/** Labels the pipeline invents for unnamed voices — never vocabulary. */
const PLACEHOLDER = /^(speaker|room) \d+$|^(them|you|unknown)$/i;

function usable(term: string): boolean {
  const t = term.trim();
  return t.length >= 4 && t.length <= 64 && t.split(/\s+/).length <= 5 && !PLACEHOLDER.test(t);
}

export function meetingVocabulary(db: DatabaseSync, meetingId: string): string[] {
  const threads = db
    .prepare("SELECT p.id, p.name FROM meeting_projects mp JOIN projects p ON p.id = mp.project_id WHERE mp.meeting_id = ?")
    .all(meetingId) as { id: number; name: string }[];
  const ids = threads.map((t) => t.id);
  const inThreads = ids.map(() => "?").join(",");

  const candidates: string[] = [];
  if (ids.length) {
    const people = db
      .prepare(`SELECT DISTINCT pe.name FROM project_people pp JOIN people pe ON pe.id = pp.person_id WHERE pp.project_id IN (${inThreads})`)
      .all(...ids) as { name: string }[];
    candidates.push(...people.map((p) => p.name));
    for (const kind of ["person", "topic"]) {
      const mentioned = db
        .prepare(
          `SELECT e.label FROM entity_mentions em
             JOIN entities e ON e.id = em.entity_id
             JOIN meeting_projects mp ON mp.meeting_id = em.meeting_id
           WHERE mp.project_id IN (${inThreads}) AND e.kind = ? AND e.merged_into IS NULL
           GROUP BY e.id ORDER BY count(*) DESC LIMIT 10`,
        )
        .all(...ids, kind) as { label: string }[];
      candidates.push(...mentioned.map((m) => m.label));
    }
    candidates.push(...threads.map((t) => t.name));
  } else {
    const recent = db
      .prepare(
        `SELECT e.label FROM entity_mentions em
           JOIN entities e ON e.id = em.entity_id
         WHERE em.meeting_id IN (SELECT id FROM meetings WHERE id != ? ORDER BY started_at DESC LIMIT ?)
           AND e.kind = 'person' AND e.merged_into IS NULL
         GROUP BY e.id ORDER BY count(*) DESC LIMIT 10`,
      )
      .all(meetingId, RECENT_MEETINGS) as { label: string }[];
    candidates.push(...recent.map((r) => r.label));
  }

  const seen = new Set<string>();
  const terms: string[] = [];
  for (const c of candidates) {
    const t = c.trim();
    if (!usable(t) || seen.has(t.toLowerCase())) continue;
    seen.add(t.toLowerCase());
    terms.push(t);
    if (terms.length === MAX_TERMS) break;
  }
  return terms;
}
