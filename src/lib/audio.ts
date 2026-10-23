/**
 * Upload-sized audio. A tape is raw PCM16 mono 16 kHz — 1.9 MB a minute as
 * WAV — and PyAI refuses large uploads (HTTP 413 at 48 MB; 28 MB accepted).
 * PyAI's diarized jobs also reject AAC ("Hear could not process this
 * transcription request") while accepting FLAC, so the encoding is lossless
 * FLAC via macOS's built-in afconvert: ~0.68 MB a minute. A tape that would
 * still exceed MAX_BYTES goes as 8 kHz FLAC, about half that again. Anywhere
 * afconvert is missing or fails, the WAV goes up unchanged.
 */
import { execFile } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import path from "node:path";
import { pcm16ToWav } from "./openai.js";

export type UploadAudio = { data: Buffer; type: string; name: string };

const AFCONVERT = "/usr/bin/afconvert";
const MAX_BYTES = 28_000_000; // largest upload observed to succeed

function afconvert(args: string[]): Promise<void> {
  return new Promise((resolve, reject) =>
    execFile(AFCONVERT, args, { timeout: 300_000 }, (err) => (err ? reject(err) : resolve())),
  );
}

export async function encodeForUpload(pcm: Buffer): Promise<UploadAudio> {
  const wav = pcm16ToWav(pcm);
  if (!existsSync(AFCONVERT)) return { data: wav, type: "audio/wav", name: "audio.wav" };
  // Meeting audio stays under data/ with everything else, not in a shared /tmp.
  mkdirSync("data", { recursive: true });
  const tmp = mkdtempSync(path.join("data", "upload-"));
  try {
    const input = path.join(tmp, "audio.wav");
    const output = path.join(tmp, "audio.flac");
    writeFileSync(input, wav);
    await afconvert(["-f", "flac", "-d", "flac", "-c", "1", input, output]);
    let data = readFileSync(output);
    if (data.length > MAX_BYTES) {
      await afconvert(["-f", "flac", "-d", "flac@8000", "-c", "1", input, output]);
      data = readFileSync(output);
    }
    return { data, type: "audio/flac", name: "audio.flac" };
  } catch {
    return { data: wav, type: "audio/wav", name: "audio.wav" }; // encoding is an optimisation, never a failure
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
}
