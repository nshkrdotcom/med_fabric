import assert from "node:assert/strict";
import {createHash} from "node:crypto";
import {readFile} from "node:fs/promises";
import {chromium} from "playwright";
import {microphone} from "../browser/microphone.mjs";
import {captureWire} from "../browser/media.mjs";

const cfg = JSON.parse(await readFile(process.argv[2], "utf8"));
const encounter = cfg.encounters[0];
const root = `http://localhost:${cfg.http_port}/encounters/${encounter.exam}`;
const mic = await microphone();
const browser = await chromium.launch({args: mic.args});
try {
  const patient = await browser.newContext({permissions: ["microphone"]});
  const clinician = await browser.newContext({permissions: ["microphone"]});
  const p = await patient.newPage(), c = await clinician.newPage();
  const finishWire = captureWire(p);
  await Promise.all([p.goto(root + "?key=" + encodeURIComponent(encounter.patient_key)),
    c.goto(root + "?key=" + encodeURIComponent(encounter.clinician_key))]);
  await Promise.all([p.waitForSelector(".phx-connected"), c.waitForSelector(".phx-connected")]);
  await p.locator("#capture [data-start]").click();
  await p.locator("#capture [data-finish]:enabled").waitFor();
  // At least a real second of production, acknowledged through the common writer.
  await p.waitForFunction(() => BigInt(document.querySelector("#capture").dataset.samples || "0") >= 48000n);
  await p.locator("#capture [data-finish]").click();
  await p.waitForFunction(() => document.querySelector("#capture").dataset.state === "ready");
  const acquisition = await p.locator("#capture").getAttribute("data-acquisition");
  assert.ok(acquisition);
  const wire = finishWire();
  await c.goto(root + "/devices");
  const row = c.locator("#acquisition-" + acquisition);
  const links = row.locator("audio[src*='/segment/audio/']");
  await links.first().waitFor({timeout: 30000});
  let count = 0n;
  const digest = createHash("sha256");
  for (const audio of await links.all()) {
    const url = new URL(await audio.getAttribute("src"), c.url());
    const response = await c.request.get(url.href);
    assert.equal(response.status(), 200);
    const bytes = await response.body();
    assert.equal(bytes.toString("ascii", 0, 4), "RIFF");
    assert.equal(bytes.readUInt32LE(24), 48000);
    assert.equal(bytes.readUInt32LE(40), bytes.length - 44);
    digest.update(bytes.subarray(44)); count += BigInt((bytes.length - 44) / 2);
    assert.ok([403, 404].includes((await p.request.get(url.href)).status()));
    url.searchParams.set("revision", "0".repeat(64));
    assert.ok([403, 404, 409].includes((await c.request.get(url.href)).status()));
  }
  assert.equal(count.toString(), wire.samples);
  assert.equal(digest.digest("hex"), wire.sha256);
  await c.goto(root);
  await c.locator('input[name="value"]').fill("76");
  await c.getByRole("button", {name: "Record manual evidence"}).click();
  await c.getByText("Manual pulse 76 /min").first().waitFor();
  console.log(JSON.stringify({acquisition, wire, verifiedPlayback: true, nativeManualEvidence: true}));
} finally {
  await browser.close();
  await mic.close();
}
