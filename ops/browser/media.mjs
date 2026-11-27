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

// Independent wire oracle. It observes exact outbound MEX1 bytes, never calls
// the producer encoder, and deduplicates only byte-identical retransmissions.
export function captureWire(patient) {
  const records = new Map();
  let finish = false, terminal = null, failure = null;
  const keys = ["stream_id", "source_epoch", "descriptor_ref", "fence", "journal_id",
    "journal_generation", "journal_digest", "accepted_sequence", "accepted_sample",
    "durable_sequence", "durable_sample"].sort();
  patient.on("websocket", socket => {
    if (!new URL(socket.url()).pathname.endsWith("/acquisitions/browser/stream")) return;
    socket.on("framesent", ({payload}) => {
      try {
        if (!Buffer.isBuffer(payload)) {
          const value = JSON.parse(payload);
          assert.equal(value.schema, "medex.acquisition.v2");
          if (value.type === "finish") finish = true;
          if (value.type === "gap") throw new Error("Clean microphone fixture lost source samples");
          return;
        }
        assert.ok(!finish, "no new source data after terminal request");
        assert.ok(payload.length >= 49 && payload.length <= 65584);
        assert.equal(payload.toString("ascii", 0, 4), "MEX1");
        assert.equal(payload.readUInt8(4), 1);
        assert.equal(payload.readUInt8(5), 0);
        assert.equal(payload.readUInt16BE(6), 48);
        assert.equal(payload.readUInt32BE(44), 0);
        assert.equal(payload.readUInt32BE(40), payload.length - 48);
        const sequence = payload.readBigUInt64BE(20);
        const sample = payload.readBigUInt64BE(28);
        const count = BigInt(payload.readUInt32BE(36));
        assert.equal(count * 2n, BigInt(payload.length - 48));
        assert.ok(count > 0n);
        const previous = records.get(sequence);
        if (previous) assert.deepEqual(previous.raw, payload, "exact retransmission");
        else records.set(sequence, {sequence, sample, count, raw: Buffer.from(payload)});
      } catch (error) { failure ||= error; }
    });
    socket.on("framereceived", ({payload}) => {
      try {
        if (Buffer.isBuffer(payload)) return;
        const value = JSON.parse(payload);
        assert.equal(value.schema, "medex.acquisition.v2");
        if (value.type === "stream_finished") {
          assert.deepEqual(Object.keys(value.receipt).sort(), keys);
          for (const key of ["source_epoch", "journal_generation", "accepted_sequence",
            "accepted_sample", "durable_sequence", "durable_sample"]) {
            assert.match(value.receipt[key], /^(0|[1-9][0-9]*)$/);
          }
          assert.equal(value.receipt.accepted_sequence, value.receipt.durable_sequence);
          assert.equal(value.receipt.accepted_sample, value.receipt.durable_sample);
          terminal = value.receipt;
        }
      } catch (error) { failure ||= error; }
    });
  });
  return () => {
    if (failure) throw failure;
    assert.ok(finish && terminal && records.size > 0, "durable terminal acknowledgement");
    const ordered = [...records.values()].sort((a, b) => a.sequence < b.sequence ? -1 : 1);
    let sample = 0n, sequence = 0n;
    const hash = createHash("sha256");
    for (const frame of ordered) {
      assert.equal(frame.sequence, sequence++);
      assert.equal(frame.sample, sample);
      sample += frame.count;
      hash.update(frame.raw.subarray(48));
    }
    assert.equal(BigInt(terminal.durable_sequence), sequence);
    assert.equal(BigInt(terminal.durable_sample), sample);
    return {samples: sample.toString(), frames: sequence.toString(), sha256: hash.digest("hex"),
      receipt: terminal};
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
