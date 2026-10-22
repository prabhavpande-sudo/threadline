/**
 * On-device transcription with whisper.cpp — the path where audio never
 * leaves the laptop. scripts/setup-local-asr.sh builds the binary and fetches
 * the models into data/local-asr/. Used two ways:
 *   THREADLINE_TRANSCRIBE=local — no speech API at all: no live stream, and
 *                                 each saved tape is transcribed at stop
 *   unset                       — first fallback when the speech API returns
 *                                 nothing, ahead of the cloud Whisper fallback
 *
 * Silero VAD skips silent stretches when its model is present: Whisper left
 * alone "transcribes" silence into stock phrases, and those would become
 * ungrounded claims downstream.
 */
import { execFile } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import type { Utterance } from "./pyai.js";

const DIR = "data/local-asr";
const BIN = path.join(DIR, "whisper-cli");

function findModel(pattern: RegExp): string | null {
  if (!existsSync(DIR)) return null;
  const f = readdirSync(DIR).find((n) => pattern.test(n));
  return f ? path.join(DIR, f) : null;
}
const speechModel = () => findModel(/^ggml-(?!silero).*\.bin$/);
const vadModel = () => findModel(/^ggml-silero.*\.bin$/);

/** THREADLINE_TRANSCRIBE=local: never send audio to a speech API. */
export function localTranscribeOnly(): boolean {
  return process.env.THREADLINE_TRANSCRIBE === "local";
}

export function hasLocalAsr(): boolean {
  return existsSync(BIN) && speechModel() != null;
}

type WhisperJson = { transcription?: { offsets: { from: number; to: number }; text: string }[] };

/** Transcribe one channel's WAV on this machine; returns utterances with offsets. */
export async function localTranscribe(
  wav: Buffer,
  speaker: string,
  speakerRole: "agent" | "customer",
  vocabulary: string[] = [],
): Promise<Utterance[]> {
  const model = speechModel();
  if (!existsSync(BIN) || !model) throw new Error("local transcription not set up — run npm run setup:local-asr");
  // Temp audio stays under data/ with everything else, not in a shared /tmp.
  const tmp = mkdtempSync(path.join(DIR, "tmp-"));
  try {
    const input = path.join(tmp, "audio.wav");
    writeFileSync(input, wav);
    const args = ["-m", model, "-f", input, "-oj", "-of", path.join(tmp, "out"), "-l", "auto", "-np",
      "-t", String(Math.max(1, os.cpus().length - 2))];
    const vad = vadModel();
    if (vad) args.push("--vad", "--vad-model", vad);
    // Whisper's initial prompt biases spelling toward the names it contains.
    if (vocabulary.length) args.push("--prompt", `${vocabulary.join(", ")}.`);
    const audioS = (wav.length - 44) / 32_000;
    await new Promise<void>((resolve, reject) =>
      execFile(BIN, args, { timeout: Math.max(300_000, Math.ceil(audioS * 2000)), maxBuffer: 16 << 20 }, (err, _out, stderr) =>
        err ? reject(new Error(`local transcription failed: ${String(stderr).trim().slice(-300) || err.message}`)) : resolve(),
      ),
    );
    // With VAD on, a tape with no speech at all writes no JSON: that's zero lines.
    const out = path.join(tmp, "out.json");
    if (!existsSync(out)) return [];
    const data = JSON.parse(readFileSync(out, "utf8")) as WhisperJson;
    return (data.transcription ?? [])
      .map((s) => ({ ...s, text: s.text.trim() }))
      .filter((s) => s.text && !/^\[.*\]$|^\(.*\)$/.test(s.text)) // [BLANK_AUDIO], (music) and the like
      .map((s) => ({
        speaker,
        speaker_role: speakerRole,
        text: s.text,
        offset_s: s.offsets.from / 1000,
        duration_s: Math.max(0.3, (s.offsets.to - s.offsets.from) / 1000),
      }));
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
}
