import assert from "node:assert/strict";
import {createHash} from "node:crypto";
import {setTimeout as delay} from "node:timers/promises";
import {toneHz} from "./microphone.mjs";

// Sample on the receiving browser's monotonic clock across peer replacement.
export async function watchReceiver(page) {
  await page.evaluate(() => {
    const streams = window.fabricMedia = {"#talkback": [], "#live-preview": []};
    const read = async () => {
      try {
        for (const [id, history] of Object.entries(streams)) {
          const peer = document.querySelector(id)?.medExPeer;
          if (peer?.connectionState !== "connected") continue;
          const stats = [...(await peer.getStats()).values()];
          const audio = stats.find(s => s.type === "inbound-rtp" && s.kind === "audio");
          if (!audio?.totalSamplesReceived) continue;
          const now = performance.now();
          if (history.at(-1)?.peer !== peer) history.push({peer, first: now, samples: 0});
          const epoch = history.at(-1);
          if (audio.totalSamplesReceived > epoch.samples) {
            epoch.last = now;
            epoch.samples = audio.totalSamplesReceived;
          }
        }
      } finally {
        setTimeout(() => void read().catch(() => {}), 50);
      }
    };
    void read().catch(() => {});
  });
}

export async function mediaGap(page, id) {
  await page.waitForFunction(id => window.fabricMedia[id].length >= 2, id);
  return page.evaluate(id => {
    const epochs = window.fabricMedia[id];
    return Math.round(epochs.at(-1).first - epochs.at(-2).last);
  }, id);
}

export async function rtpStats(page, id, relay) {
  // Poll in Node so each async getStats() result is resolved before testing readiness.
  const deadline = performance.now() + 30_000;
  let result;
  do {
    result = await page.evaluate(readRtpStats, id);
    if (result) break;
    await delay(50);
  } while (performance.now() < deadline);

  assert.ok(result, id + " decoded RTP and selected ICE pair");
  assert.ok(Number.isFinite(result.jitterSeconds) && Number.isFinite(result.lost), id + " loss and jitter");
  if (relay) {
    assert.equal(result.policy, "relay", id + " policy");
    assert.equal(result.local.candidateType, "relay", id + " local pair member");
    assert.equal(result.remote.candidateType, "relay", id + " remote pair member");
  }
  return result;
}

async function readRtpStats(id) {
  const pc = document.querySelector(id).medExPeer;
  if (pc?.connectionState !== "connected") return false;
  const report = await pc.getStats();
  const stats = [...report.values()];
  const audio = stats.find(s => s.type === "inbound-rtp" && s.kind === "audio");
  if (!(audio?.packetsReceived > 10 && audio.totalSamplesReceived > 0)) return false;
  const pair = report.get(report.get(audio.transportId)?.selectedCandidatePairId);
  if (pair?.state !== "succeeded") return false;
  const describe = candidate => candidate && ({
    candidateType: candidate.candidateType, protocol: candidate.protocol,
    relayProtocol: candidate.relayProtocol
  });
  const local = describe(report.get(pair.localCandidateId));
  const remote = describe(report.get(pair.remoteCandidateId));
  if (!local?.candidateType || !remote?.candidateType) return false;
  return {policy: pc.getConfiguration().iceTransportPolicy, local, remote,
    roundTripSeconds: pair.currentRoundTripTime,
    received: audio.packetsReceived, lost: audio.packetsLost, jitterSeconds: audio.jitter,
    decodedSamples: audio.totalSamplesReceived};
}

export async function previewSignal(page) {
  const result = await page.evaluate(async hz => {
    const stream = document.querySelector("#live-preview audio").srcObject;
    const context = new AudioContext();
    try {
      await context.resume();
      const analyser = context.createAnalyser();
      analyser.fftSize = 4096;
      analyser.smoothingTimeConstant = 0;
      const source = context.createMediaStreamSource(stream);
      const mute = context.createGain();
      mute.gain.value = 0;
      source.connect(analyser).connect(mute).connect(context.destination);
      const bins = new Float32Array(analyser.frequencyBinCount);
      const values = new Float32Array(analyser.fftSize);
      const deadline = performance.now() + 10000;
      let peakHz, rms;
      do {
        await new Promise(resolve => setTimeout(resolve, 100));
        analyser.getFloatFrequencyData(bins);
        analyser.getFloatTimeDomainData(values);
        rms = Math.sqrt(values.reduce((sum, x) => sum + x*x, 0) / values.length);
        const peak = bins.indexOf(Math.max(...bins));
        peakHz = peak * context.sampleRate / analyser.fftSize;
        if (rms > 0.01 && Math.abs(peakHz - hz) < 30) break;
      } while (performance.now() < deadline);
      return {peakHz, rms};
    } finally {
      await context.close();
    }
  }, toneHz);
  assert.ok(result.rms > 0.01 && Math.abs(result.peakHz - toneHz) < 30, JSON.stringify(result));
  return result;
}

export function captureWire(patient) {
  let nextSample = 0, malformed = false, finish = false;
  const hash = createHash("sha256");
  patient.on("websocket", socket => {
    if (!new URL(socket.url()).pathname.endsWith("/pcm")) return;
    socket.on("framesent", ({payload}) => {
      if (payload === "finish") finish = true;
      if (!Buffer.isBuffer(payload)) return;
      if (finish || payload.length < 10 || payload.length > 1928 || payload.length % 2 ||
          payload.readBigUInt64BE() !== BigInt(nextSample)) {
        malformed = true;
        return;
      }
      const pcm = payload.subarray(8);
      nextSample += pcm.length / 2;
      hash.update(pcm);
    });
  });
  return () => {
    assert.ok(finish && !malformed && nextSample > 0, "ordered indexed PCM followed by finish");
    return {samples: nextSample, sha256: hash.digest("hex")};
  };
}

export function recordedSignal(wav) {
  // Inspect 100 ms windows, allowing an initial silent input ramp.
  const count = 4800;
  for (let offset = 44; offset + 2 * count <= wav.length; offset += 2 * count) {
    let crossings = 0, energy = 0, previous = 0;
    for (let i = 0; i < count; i++) {
      const next = wav.readInt16LE(offset + 2*i) / 32768;
      if (previous <= 0 && next > 0) crossings++;
      energy += next * next;
      previous = next;
    }
    const rms = Math.sqrt(energy / count);
    const frequencyHz = crossings * 48000 / count;
    if (rms > 0.01 && Math.abs(frequencyHz - toneHz) < 30) return {frequencyHz, rms};
  }
  assert.fail("WAV has no non-silent window with the expected microphone frequency");
}
