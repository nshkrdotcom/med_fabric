import {mkdtemp, rm, writeFile} from "node:fs/promises";
import {tmpdir} from "node:os";
import {join} from "node:path";

export const toneHz = 997;

export async function microphone() {
  const dir = await mkdtemp(join(tmpdir(), "fabric-mic-"));
  const path = join(dir, "diagnostic.wav");
  const rate = 48000;
  const wav = Buffer.alloc(44 + 2 * rate);
  wav.write("RIFF", 0);
  wav.writeUInt32LE(wav.length - 8, 4);
  wav.write("WAVEfmt ", 8);
  wav.writeUInt32LE(16, 16);
  wav.writeUInt16LE(1, 20);
  wav.writeUInt16LE(1, 22);
  wav.writeUInt32LE(rate, 24);
  wav.writeUInt32LE(2 * rate, 28);
  wav.writeUInt16LE(2, 32);
  wav.writeUInt16LE(16, 34);
  wav.write("data", 36);
  wav.writeUInt32LE(wav.length - 44, 40);
  for (let i = 0; i < rate; i++) {
    wav.writeInt16LE(Math.round(8000 * Math.sin(2 * Math.PI * toneHz * i / rate)), 44 + 2 * i);
  }
  await writeFile(path, wav, {mode: 0o600});
  return {
    args: ["--use-fake-device-for-media-stream", "--use-fake-ui-for-media-stream",
      "--autoplay-policy=no-user-gesture-required", "--use-file-for-fake-audio-capture=" + path],
    close: () => rm(dir, {recursive: true, force: true})
  };
}
