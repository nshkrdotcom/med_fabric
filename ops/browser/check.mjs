import assert from "node:assert/strict";
import {createHash} from "node:crypto";
import {readFile, writeFile} from "node:fs/promises";
import {chromium} from "playwright";
import {microphone} from "./microphone.mjs";
import {captureWire, rtpStats, watchReceiver} from "./media.mjs";

const env = process.env;
const remote = process.argv.includes("--relay");
const capture = process.argv.includes("--capture");
const afterRestart = process.argv.includes("--after-restart");
const encounter = env.MF_EXAM_ID;
assert.ok(encounter && env.MF_BROWSER_EVIDENCE, "MF_EXAM_ID and MF_BROWSER_EVIDENCE required");
const origin = remote ? env.MF_PUBLIC_ORIGIN : `http://127.0.0.1:${env.MF_HTTP_PORT}`;
const url = new URL("/encounters/" + encodeURIComponent(encounter), origin).href;
if (remote) {
  assert.equal(new URL(url).protocol, "https:");
  assert.ok(env.MF_PATIENT_BROWSER_WS && env.MF_CLINICIAN_BROWSER_WS);
  assert.notEqual(env.MF_PATIENT_BROWSER_WS, env.MF_CLINICIAN_BROWSER_WS);
}
const metrics = {encounter, relayOnly: remote};
const browsers = [];
let mic, local;

async function enter(role) {
  const prefix = "MF_" + role.toUpperCase();
  let browser, storageState;
  if (remote) {
    browser = await chromium.connect(env[prefix + "_BROWSER_WS"]);
    browsers.push(browser);
    storageState = env[prefix + "_STORAGE_STATE"];
    assert.ok(storageState, role + " authenticated storage state required");
  } else {
    if (!local) {
      mic = await microphone();
      local = await chromium.launch({args: mic.args}); browsers.push(local);
    }
    browser = local;
  }
  const context = await browser.newContext({permissions: ["microphone"], storageState});
  const page = await context.newPage();
  if (remote) await page.goto(url);
  else {
    assert.equal((await page.request.get(url)).status(), 403);
    await page.goto(url + "?key=" + encodeURIComponent(env[prefix + "_ACCESS_KEY"]));
  }
  await page.waitForSelector(".phx-connected");
  assert.equal(await page.locator("#talkback").getAttribute("data-role"), role);
  return page;
}

async function conversation(patient, clinician) {
  const [p, c] = await Promise.all([rtpStats(patient, "#talkback", remote),
    rtpStats(clinician, "#talkback", remote)]);
  return {patient: p, clinician: c};
}

async function segments(clinician, patient, acquisition) {
  await clinician.goto(url + "/devices");
  const row = clinician.locator("#acquisition-" + acquisition);
  const audio = row.locator("audio[src*='/segment/audio/']");
  await audio.first().waitFor({timeout: 30000});
  const result = {acquisition, digest: await row.getAttribute("data-digest"), samples: 0, segments: []};
  const hash = createHash("sha256");
  for (const element of await audio.all()) {
    const source = new URL(await element.getAttribute("src"), clinician.url());
    const response = await clinician.request.get(source.href);
    assert.equal(response.status(), 200);
    const wav = await response.body();
    assert.equal(wav.toString("ascii", 0, 4), "RIFF");
    assert.equal(wav.readUInt32LE(24), 48000);
    assert.equal(wav.readUInt32LE(40), wav.length - 44);
    assert.equal(Number(await element.getAttribute("data-first-sample")), result.samples);
    result.samples += (wav.length - 44) / 2;
    hash.update(wav.subarray(44));
    result.segments.push({source: source.href, sha256: createHash("sha256").update(wav).digest("hex")});
    if (patient) assert.ok([403, 404].includes((await patient.request.get(source.href)).status()));
    source.searchParams.set("revision", "0".repeat(64));
    assert.ok([403, 404, 409].includes((await clinician.request.get(source.href)).status()));
  }
  result.sha256 = hash.digest("hex");
  return result;
}

try {
  const clinician = await enter("clinician");
  if (capture) {
    const patient = await enter("patient");
    const finishWire = captureWire(patient);
    await watchReceiver(clinician);
    await clinician.locator("#talkback button").click();
    await patient.locator("#talkback button").click();
    metrics.talkback = await conversation(patient, clinician);
    await patient.locator("#capture [data-start]").click();
    await patient.waitForFunction(() => BigInt(document.querySelector("#capture").dataset.samples || "0") >= 48000n);
    await patient.locator("#capture [data-finish]").click();
    await patient.waitForFunction(() => document.querySelector("#capture").dataset.state === "ready");
    const wire = finishWire();
    const acquisition = await patient.locator("#capture").getAttribute("data-acquisition");
    const verified = await segments(clinician, patient, acquisition);
    assert.equal(String(verified.samples), wire.samples);
    assert.equal(verified.sha256, wire.sha256);
    metrics.acquisition = verified; metrics.wire = wire;

    // Capture and direct talkback are separate. Returning to the encounter
    // establishes fresh signaling authority; neither path creates FHIR waveform data.
    await clinician.goto(url); await clinician.waitForSelector(".phx-connected");
    await clinician.locator("#talkback button").click();
    await patient.reload(); await patient.waitForSelector(".phx-connected");
    await patient.locator("#talkback button").click();
    metrics.rejoinedTalkback = await conversation(patient, clinician);
    await clinician.locator('input[name="value"]').fill("70");
    await clinician.getByRole("button", {name: "Record manual evidence"}).click();
    await clinician.getByText("Manual pulse 70 /min").waitFor();
    await writeFile(env.MF_BROWSER_EVIDENCE, JSON.stringify(metrics));
  } else {
    const previous = JSON.parse(await readFile(env.MF_BROWSER_EVIDENCE, "utf8"));
    const verified = await segments(clinician, null, previous.acquisition.acquisition);
    assert.deepEqual(verified, previous.acquisition, "exact verified segments survive process restart");
    const row = clinician.locator("#acquisition-" + verified.acquisition);
    if (!afterRestart) {
      const form = row.locator("form[id^='review-']");
      if (await form.count()) {
        const defects = JSON.parse(await form.getAttribute("data-defects"));
        await form.locator('[name="decision"]').selectOption(defects.length ? "partial" : "complete");
        await form.locator('[name="range"]').fill(`audio:0:${verified.samples}`);
        await form.locator('[name="note"]').fill("Synthetic browser capture verified; clock uncertainty retained");
        if (defects.length) await form.locator('[name="acknowledged"]').check();
        await form.getByRole("button", {name: "Save clinical decision"}).click();
        await row.getByText(/Clinical decision:/).waitFor();
      }
    }
    await clinician.goto(url); await clinician.waitForSelector(".phx-connected");
    const manual = clinician.locator('article[id^="native-manual-"]').filter({hasText: "Manual pulse 70 /min"}).first();
    if (!afterRestart && await manual.locator("[data-accept]").count()) await manual.locator("[data-accept]").click();
    await manual.getByText("Clinically accepted", {exact: true}).waitFor();
    if (!afterRestart && await manual.getByRole("button", {name: "Request delivery"}).count()) {
      await manual.getByRole("button", {name: "Request delivery"}).click();
    }
    await manual.getByText("Export: confirmed", {exact: true}).waitFor({timeout: 60000});
    const ref = await manual.getAttribute("data-remote-ref");
    assert.match(ref || "", /^Observation\/[A-Za-z0-9.-]+$/);
    if (afterRestart) assert.equal(ref, previous.remote);
    assert.ok(env.FHIR_BASE_URL);
    const base = env.FHIR_BASE_URL.replace(/\/$/, "");
    // Never forward a browser session cookie to the external FHIR server.
    const response = await fetch(base + "/" + ref, {headers: {Accept: "application/fhir+json"}});
    assert.equal(response.status, 200);
    const resource = await response.json();
    assert.equal(resource.valueQuantity.value, 70); assert.equal(resource.valueQuantity.code, "/min");
    const identity = resource.identifier.find(i => i.system.startsWith("urn:uuid:"));
    assert.ok(identity);
    const search = new URL(base + "/Observation");
    search.searchParams.set("identifier", identity.system + "|" + identity.value);
    const found = await fetch(search, {headers: {Accept: "application/fhir+json"}});
    assert.equal(found.status, 200); assert.equal((await found.json()).total, 1);
    metrics.remote = ref; metrics.acquisition = verified;
    await writeFile(env.MF_BROWSER_EVIDENCE, JSON.stringify({...previous, ...metrics}));
  }
  console.log(JSON.stringify(metrics));
} finally {
  await Promise.all(browsers.map(browser => browser.close())); await mic?.close();
}
