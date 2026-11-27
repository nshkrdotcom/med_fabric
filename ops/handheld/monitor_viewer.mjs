import assert from "node:assert/strict";
import {access, readFile, writeFile} from "node:fs/promises";
import {setTimeout as delay} from "node:timers/promises";
import {chromium} from "playwright";

const [file, id, ready, stop, metrics, seconds = "60", sourceRoot] = process.argv.slice(2);
const cfg = JSON.parse(await readFile(file, "utf8")), encounter = cfg.encounters[0];
const root = `http://localhost:${cfg.http_port}/encounters/${encounter.exam}`;
const browser = await chromium.launch({args: ["--autoplay-policy=no-user-gesture-required"]});
try {
  const page = await browser.newPage();
  await page.goto(root + "?key=" + encodeURIComponent(encounter.clinician_key));
  await page.goto(root + "/devices");
  const view = page.locator("#monitor-" + id);
  await view.locator("button").click();
  await page.waitForFunction(id => {
    const monitor = document.getElementById("monitor-" + id);
    const audio = monitor?.querySelector("audio");
    return monitor?.querySelector("output").textContent.toLowerCase() === "connected" &&
      audio?.srcObject?.getAudioTracks()[0]?.readyState === "live" && audio.currentTime > 0.1;
  }, id, {timeout: 25000});
  await writeFile(ready, "received actual decoded synthetic monitor audio\n");
  if (!stop) {
    await page.waitForFunction(id => {
      const output = document.querySelector("#monitor-" + id + " output");
      return output && /disconnected|closed|expired|unavailable/i.test(output.textContent);
    }, id, {timeout: 45000});
  } else {
    const observations = [];
    const started = performance.now();
    const deadline = started + (Number(seconds) + 120) * 1000;
    let previous = null;
    const sourceDone = async () => {
      if (!sourceRoot) return false;
      const marks = await Promise.all(["audio", "ecg"].map(name =>
        readFile(`${sourceRoot}/${name}/source.json`, "utf8")
          .then(bytes => JSON.parse(bytes)).catch(() => null)));
      return marks.every(mark => mark?.done === true && !mark.interruption);
    };
    let sourceCompleted = false;
    while (performance.now() < deadline) {
      const done = await access(stop).then(() => true, () => false);
      sourceCompleted = await sourceDone();
      if (done || sourceCompleted) break;
      const sample = await page.evaluate(async id => {
        const monitor = document.getElementById("monitor-" + id);
        const peer = monitor?.medExPeer;
        if (!peer || peer.connectionState !== "connected") return {connected: false};
        const reports = [...(await peer.getStats()).values()];
        const audio = reports.find(s => s.type === "inbound-rtp" && s.kind === "audio");
        return {connected: true, decodedSamples: audio?.totalSamplesReceived || 0,
          packets: audio?.packetsReceived || 0, lost: audio?.packetsLost || 0,
          jitterSeconds: audio?.jitter || 0};
      }, id);
      sample.elapsedMs = Math.round(performance.now() - started);
      if (!sample.connected && await sourceDone()) { sourceCompleted = true; break; }
      assert.ok(sample.connected, "clean soak monitor remained connected and renewed");
      if (previous) assert.ok(sample.decodedSamples > previous.decodedSamples,
        "clean soak monitor keeps decoding real RTP");
      observations.push(sample); previous = sample;
      await writeFile(metrics, JSON.stringify({startedAt: Date.now() - sample.elapsedMs,
        elapsedMs: sample.elapsedMs, observations}));
      await delay(1000);
    }
    assert.ok(sourceCompleted || await access(stop).then(() => true, () => false),
      "actual source completion or capture coordinator stopped viewer");
    assert.ok(observations.length >= 2, "multiple actual media observations");
    await writeFile(metrics, JSON.stringify({elapsedMs: performance.now() - started,
      observations, stopped: true, stopReason: sourceCompleted ? "source_complete" : "coordinator"}));
  }
} finally { await browser.close(); }
