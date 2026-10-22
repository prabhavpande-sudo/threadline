/**
 * Name diarized call voices from the meeting app's own "who's speaking" cue.
 * During a take, capture/threadline-speakers samples the name the meeting app
 * highlights; those land in speaker_hints on the utterances' clock. After the
 * diarized transcript is written, each hint votes for the call-side voice
 * ("Speaker N") speaking at that moment. A voice takes a name only with at
 * least MIN_VOTES votes and a MIN_SHARE majority, and each name goes to one
 * voice (strongest first). Room voices never get hints — the app can't see
 * who's talking in your room — so "Room N" is left for a human.
 */
import type { DatabaseSync } from "node:sqlite";

const MIN_VOTES = 3;
const MIN_SHARE = 0.6;
const SLACK_S = 0.5; // hint sampling and ASR turn edges don't line up exactly

export type SpeakerNaming = { from: string; to: string; votes: number; share: number };

export function nameSpeakersFromHints(db: DatabaseSync, meetingId: string): SpeakerNaming[] {
  const hints = db
    .prepare("SELECT offset_s, name FROM speaker_hints WHERE meeting_id = ? ORDER BY offset_s")
    .all(meetingId) as { offset_s: number; name: string }[];
  if (!hints.length) return [];
  const turns = db
    .prepare("SELECT speaker, offset_s, duration_s FROM utterances WHERE meeting_id = ? AND speaker LIKE 'Speaker %' ORDER BY offset_s")
    .all(meetingId) as { speaker: string; offset_s: number; duration_s: number }[];

  // votes[speaker][name] = count
  const votes = new Map<string, Map<string, number>>();
  for (const h of hints) {
    const turn = turns.find((t) => h.offset_s >= t.offset_s - SLACK_S && h.offset_s <= t.offset_s + t.duration_s + SLACK_S);
    if (!turn) continue;
    const forSpeaker = votes.get(turn.speaker) ?? new Map<string, number>();
    forSpeaker.set(h.name, (forSpeaker.get(h.name) ?? 0) + 1);
    votes.set(turn.speaker, forSpeaker);
  }

  const candidates: SpeakerNaming[] = [];
  for (const [speaker, byName] of votes) {
    const total = [...byName.values()].reduce((a, b) => a + b, 0);
    const [name, n] = [...byName.entries()].sort((a, b) => b[1] - a[1])[0];
    if (n >= MIN_VOTES && n / total >= MIN_SHARE) candidates.push({ from: speaker, to: name, votes: n, share: n / total });
  }

  // One name per voice: strongest evidence claims the name first.
  const taken = new Set<string>();
  const named: SpeakerNaming[] = [];
  for (const c of candidates.sort((a, b) => b.votes - a.votes)) {
    if (taken.has(c.to.toLowerCase())) continue;
    taken.add(c.to.toLowerCase());
    db.prepare("UPDATE utterances SET speaker = ? WHERE meeting_id = ? AND speaker = ?").run(c.to, meetingId, c.from);
    db.prepare("INSERT INTO people (name, created_at) VALUES (?, ?) ON CONFLICT(name) DO NOTHING").run(c.to, Date.now());
    named.push(c);
  }
  return named;
}
