import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { chromium } from "playwright";

const encounterId = process.env.MF_EXAM_ID;
const path = `http://127.0.0.1:${process.env.MF_HTTP_PORT}/encounters/${encounterId}`;
const url = `${path}?key=${encodeURIComponent(process.env.MF_LAB_ACCESS_KEY)}`;
const observationId = `obs:${encounterId}:circor-1`;
const browser = await chromium.launch();

try {
  const page = await browser.newPage();
  const rejected = await page.request.get(path);
  assert.equal(rejected.status(), 403);
  await page.goto(url);
  await page.waitForSelector(".phx-connected");
  const preview = page.locator("#live-preview");
  const state = () => preview.getAttribute("data-state");
  const recording = page.locator("#recording-audio");
  const fixtureDigest = "7c8c93ee4602072aa5c0e4c81a5a9e28d926b278f701218ea588bde9644efc66";

  if (!process.argv.includes("--after-restart")) {
    await page.locator("#preview-play").click();
    await page.waitForFunction(() => document.querySelector("#live-preview").dataset.state === "connected");
    const sessionId = await preview.getAttribute("data-session-id");
    const connectionId = await preview.getAttribute("data-connection-id");

    await page.locator("#start-capture").click();
    await page.locator("#capture-active").waitFor();

    async function requireAudio() {
      await page.waitForFunction(async () => {
        const element = document.querySelector("#live-preview");
        if (!element.medExPeer || !element.querySelector("audio").srcObject) return false;
        const stats = await element.medExPeer.getStats();
        return Array.from(stats.values()).some(
          item => item.type === "inbound-rtp" && item.kind === "audio" &&
            item.packetsReceived > 10 && item.totalSamplesReceived > 0
        );
      }, null, { timeout: 12_000 });
    }

    await requireAudio();
    await page.locator("#preview-disconnect").click();
    assert.equal(await state(), "disconnected");
    await page.locator("#capture-active").waitFor();
    await page.locator("#preview-reconnect").click();
    await requireAudio();
    assert.equal(await preview.getAttribute("data-session-id"), sessionId);
    assert.notEqual(await preview.getAttribute("data-connection-id"), connectionId);
    await page.locator("#capture-active").waitFor();
    console.log("Chromium received Opus audio before and after replacing the peer during capture");

    await recording.waitFor({ timeout: 32_000 });
    assert.equal(await page.locator("#recording-continuity").textContent(), "observed_continuous");
    await page.locator("#accept-recording").click();
  }

  await recording.waitFor();
  const audio = await page.request.get(`${path}/recording`);
  assert.equal(audio.status(), 200);
  const wav = await audio.body();
  assert.equal(wav.subarray(0, 4).toString(), "RIFF");
  assert.equal(wav.toString("ascii", 36, 40), "data");
  assert.equal(wav.length, 188_844);
  assert.equal(createHash("sha256").update(wav.subarray(44)).digest("hex"), fixtureDigest);
  await page.waitForFunction(id => document.querySelector("#observation-id")?.textContent === id, observationId);

  if (!process.argv.includes("--after-restart")) {
    await page.locator("#deliver-recording").click();
  }

  await page.waitForFunction(() => document.querySelector("#outbox-status")?.textContent === "delivered");
  const remote = await page.locator("#remote-reference").textContent();
  const fhirUrl = process.env.FHIR_BASE_URL.replace(/\/$/, "");
  const search = new URL(`${fhirUrl}/Observation`);
  search.searchParams.set("identifier", `urn:med-fabric:observation|urn:med_fabric:observation:${observationId}`);
  const response = await page.request.get(search.href, { headers: { Accept: "application/fhir+json" } });
  assert.equal(response.status(), 200);
  const bundle = await response.json();
  assert.equal(bundle.total, 1);
  const resource = bundle.entry[0].resource;
  assert.equal(`${resource.resourceType}/${resource.id}`, remote);
  assert.match(resource.subject.reference, /^Patient\//);
  assert.match(resource.encounter.reference, /^Encounter\//);
  assert.match(resource.valueString, new RegExp(fixtureDigest));
  console.log(`${observationId} -> ${remote} (one matching HAPI R4 resource)`);
} finally {
  await browser.close();
}
