import assert from "node:assert/strict";
import {createHash} from "node:crypto";
import {chromium} from "playwright";
import {microphone} from "./microphone.mjs";
import {captureWire, mediaGap, previewSignal, recordedSignal, rtpStats, watchReceiver} from "./media.mjs";

const env = process.env;
const remote = process.argv.includes("--relay");
const capture = process.argv.includes("--capture");
const encounter = env.MF_EXAM_ID;
assert.ok(encounter, "MF_EXAM_ID is required");
const origin = remote ? env.MF_PUBLIC_ORIGIN : `http://127.0.0.1:${env.MF_HTTP_PORT}`;
const path = new URL("/encounters/" + encodeURIComponent(encounter), origin).href;
if (remote) {
  assert.equal(new URL(path).protocol, "https:");
  assert.ok(env.MF_PATIENT_BROWSER_WS && env.MF_CLINICIAN_BROWSER_WS, "Two browser endpoints required");
  assert.notEqual(env.MF_PATIENT_BROWSER_WS, env.MF_CLINICIAN_BROWSER_WS);
}
const metrics = {encounter, relayOnly: remote};
const browsers = [];
let mic, local;

async function enter(role) {
  const prefix = "MF_" + role.toUpperCase();
  let browser;
  let storageState;
  if (remote) {
    browser = await chromium.connect(env[prefix + "_BROWSER_WS"]);
    browsers.push(browser);
    storageState = env[prefix + "_STORAGE_STATE"];
    assert.ok(storageState, role + " requires authenticated storage state");
  } else {
    if (!local) {
      mic = await microphone();
      local = await chromium.launch({args: mic.args});
      browsers.push(local);
    }
    browser = local;
  }
  const context = await browser.newContext({permissions: ["microphone"], storageState});
  const page = await context.newPage();
  if (remote) {
    await page.goto(path);
  } else {
    assert.equal((await page.request.get(path)).status(), 403);
    await page.goto(path + "?key=" + encodeURIComponent(env[prefix + "_ACCESS_KEY"]));
  }
  await page.waitForSelector(".phx-connected");
  assert.equal(await page.locator("#talkback").getAttribute("data-role"), role);
  return page;
}

async function talkback(patient, clinician) {
  const pages = [patient, clinician];
  await Promise.all(pages.map(page => page.waitForFunction(() => {
    const audio = document.querySelector("#talkback audio");
    return audio.srcObject?.active && audio.currentTime > 0.15 &&
      document.querySelector("#talkback [role=status]").textContent === "connected";
  })));
  const [patientStats, clinicianStats] = await Promise.all(pages.map(page => rtpStats(page, "#talkback", remote)));
  return {patient: patientStats, clinician: clinicianStats};
}

async function rangeResponses(clinician, patient, url, wav, etag) {
  const ranges = [[44, 127, "bytes=44-127"], [wav.length - 32, wav.length - 1, "bytes=-32"]];
  await Promise.all(ranges.map(async ([first, last, range]) => {
    const res = await clinician.request.get(url, {headers: {Range: range, "If-Range": etag}});
    assert.equal(res.status(), 206);
    assert.equal(res.headers()["content-range"], `bytes ${first}-${last}/${wav.length}`);
    assert.deepEqual(await res.body(), wav.subarray(first, last + 1));
  }));
  const invalid = await clinician.request.get(url, {headers: {Range: "bytes=" + wav.length + "-"}});
  assert.equal(invalid.status(), 416);
  assert.equal(invalid.headers()["content-range"], "bytes */" + wav.length);
  if (patient) {
    const denied = await patient.request.get(url, {headers: {Range: "bytes=0-43"}});
    assert.equal(denied.status(), 404);
  }
}

try {
  const clinician = await enter("clinician");
  let patient, wireResult;
  if (capture) {
    patient = await enter("patient");
    const finishWire = captureWire(patient);
    await watchReceiver(clinician);
    const joinedAt = performance.now();
    await clinician.locator("#talkback button").click();
    await patient.locator("#talkback button").click();
    metrics.talkback = await talkback(patient, clinician);
    metrics.talkbackJoinToMediaMs = Math.round(performance.now() - joinedAt);

    const input = patient.locator("#capture [data-input]");
    await patient.waitForFunction(() => document.querySelector("#capture [data-input]").options.length > 1);
    await input.selectOption({index: 1});
    await patient.locator("[data-start]").click();
    await patient.waitForFunction(() => document.querySelector("#capture [role=status]").textContent === "Recording");
    const previewAt = performance.now();
    await clinician.locator("#preview-play").click();
    await clinician.waitForFunction(() => document.querySelector("#live-preview").dataset.state === "connected");
    metrics.previewConnectMs = Math.round(performance.now() - previewAt);
    metrics.preview = await rtpStats(clinician, "#live-preview", remote);
    metrics.previewSignal = await previewSignal(clinician);
    const first = await clinician.locator("#live-preview").getAttribute("data-connection-id");

    // A competing clinician tab displaces the current capture subscriber.
    const secondTab = await clinician.context().newPage();
    await secondTab.goto(path);
    await secondTab.waitForSelector(".phx-connected");
    await secondTab.locator("#preview-play").click();
    await clinician.waitForFunction(() => document.querySelector("#live-preview").dataset.state === "replaced");
    await rtpStats(secondTab, "#live-preview", remote);
    await secondTab.close();
    const reconnectAt = performance.now();
    await clinician.locator("#preview-reconnect").click();
    metrics.reconnectedPreview = await rtpStats(clinician, "#live-preview", remote);
    metrics.previewReconnectToMediaMs = Math.round(performance.now() - reconnectAt);
    metrics.reconnectedSignal = await previewSignal(clinician);
    metrics.previewMediaGapMs = await mediaGap(clinician, "#live-preview");
    assert.notEqual(await clinician.locator("#live-preview").getAttribute("data-connection-id"), first);
    assert.equal(await patient.locator("#capture [role=status]").textContent(), "Recording");
    await patient.locator("[data-finish]").click({timeout: 5000});
    await patient.waitForFunction(() => document.querySelector("#capture [role=status]").textContent === "ready");
    const transport = JSON.parse(await patient.locator("#capture").getAttribute("data-transport"));
    assert.ok(transport.peakBufferedBytes > 0 && transport.peakBufferedBytes <= 32776);
    assert.ok(transport.maxAckDelayMs >= 0 && Number.isFinite(transport.maxAckDelayMs));
    metrics.pcmWebSocket = transport;
    wireResult = finishWire();

    const rejoinAt = performance.now();
    await patient.reload();
    await patient.waitForSelector(".phx-connected");
    await patient.locator("#talkback button").click();
    metrics.rejoinedTalkback = await talkback(patient, clinician);
    metrics.talkbackMediaGapMs = await mediaGap(clinician, "#talkback");
    metrics.talkbackRejoinToMediaMs = Math.round(performance.now() - rejoinAt);
    await clinician.getByRole("spinbutton").fill("70");
    await clinician.getByRole("button", {name: "Record pulse"}).click();
    await clinician.getByText("70 beats/minute").waitFor();
  }

  const recording = clinician.locator('section[id^="evidence-"]').filter({has: clinician.locator("audio")});
  const url = new URL(await recording.locator("audio").getAttribute("src"), path).href;
  const wavResponse = await clinician.request.get(url);
  assert.equal(wavResponse.status(), 200);
  assert.equal(wavResponse.headers()["accept-ranges"], "bytes");
  const wav = await wavResponse.body();
  const digest = createHash("sha256").update(wav).digest("hex");
  assert.equal(wavResponse.headers().etag, '"' + digest + '"');
  assert.equal(wav.toString("ascii", 0, 4), "RIFF");
  assert.equal(wav.readUInt32LE(24), 48000);
  assert.equal(wav.readUInt32LE(40), wav.length - 44);
  assert.ok(wav.length > 19200);
  await rangeResponses(clinician, patient, url, wav, wavResponse.headers().etag);
  if (capture) {
    const actual = createHash("sha256").update(wav.subarray(44)).digest("hex");
    assert.equal(actual, wireResult.sha256);
    assert.equal((wav.length - 44) / 2, wireResult.samples);
    metrics.recording = {...wireResult, fileSha256: digest, ...recordedSignal(wav)};
  } else {
    for (const row of await clinician.locator('section[id^="evidence-"]').all()) {
      const id = (await row.getAttribute("id")).slice("evidence-".length);
      if (!process.argv.includes("--after-restart")) {
        await row.getByRole("button", {name: "Accept"}).click();
        await row.getByRole("button", {name: "Deliver to FHIR"}).click();
      }
      const ref = row.getByText(/^Observation\//);
      await ref.waitFor();
      const search = new URL(env.FHIR_BASE_URL.replace(/\/$/, "") + "/Observation");
      search.searchParams.set("identifier", `urn:med-fabric:observation|${encounter}:${id}`);
      // Do not send the browser's actor session to a distinct FHIR service.
      const response = await fetch(search, {headers: {Accept: "application/fhir+json"}});
      assert.equal(response.status, 200);
      const bundle = await response.json();
      assert.equal(bundle.total, 1);
      const evidence = bundle.entry[0].resource;
      assert.equal("Observation/" + evidence.id, await ref.textContent());
      if (evidence.valueQuantity) {
        assert.equal(evidence.valueQuantity.value, 70);
        assert.equal(evidence.valueQuantity.code, "/min");
      } else {
        assert.equal(evidence.valueString, digest);
      }
    }
  }
  console.log(JSON.stringify(metrics));
} finally {
  await Promise.all(browsers.map(browser => browser.close()));
  await mic?.close();
}
