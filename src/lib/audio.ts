/**
 * Upload-sized audio. A tape is raw PCM16 mono 16 kHz — 1.9 MB a minute as
 * WAV, so a 25-minute call is 48 MB and speech APIs refuse it (PyAI answered
 * HTTP 413). On macOS, afconvert (built in) encodes AAC at 32 kbps mono:
 * ~0.24 MB a minute, plenty for speech. Anywhere afconvert is missing, the
 * WAV goes up unchanged.
 */
import { execFile } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import path from "node:path";
import { pcm16ToWav } from "./openai.js";

export type UploadAudio = { data: Buffer; type: string; name: string };

const AFCONVERT = "/usr/bin/afconvert";

export async function encodeForUpload(pcm: Buffer): Promise<UploadAudio> {
  const wav = pcm16ToWav(pcm);
  if (!existsSync(AFCONVERT)) return { data: wav, type: "audio/wav", name: "audio.wav" };
  // Meeting audio stays under data/ with everything else, not in a shared /tmp.
  mkdirSync("data", { recursive: true });
  const tmp = mkdtempSync(path.join("data", "upload-"));
  try {
    const input = path.join(tmp, "audio.wav");
    const output = path.join(tmp, "audio.m4a");
    writeFileSync(input, wav);
    await new Promise<void>((resolve, reject) =>
      execFile(AFCONVERT, ["-f", "m4af", "-d", "aac", "-b", "32000", "-c", "1", input, output], { timeout: 300_000 }, (err) =>
        err ? reject(err) : resolve(),
      ),
    );
    return { data: readFileSync(output), type: "audio/mp4", name: "audio.m4a" };
  } catch {
    return { data: wav, type: "audio/wav", name: "audio.wav" }; // encoding is an optimisation, never a failure
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
}
