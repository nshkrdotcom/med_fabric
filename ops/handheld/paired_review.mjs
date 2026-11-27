import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { chromium } from "playwright";

const [file, acquisition, review] = process.argv.slice(2);
const cfg = JSON.parse(await readFile(file, "utf8"));
const encounter = cfg.encounters[0];
const encounterUrl = `http://localhost:${cfg.http_port}/encounters/${encounter.exam}`;
const browser = await chromium.launch();
try {
  const page = await browser.newPage();
  await page.goto(encounterUrl + "?key=" + encounter.clinician_key);
  await page.goto(encounterUrl + "/devices");
  await page.getByRole("button", { name: "Authorize device" }).waitFor();
  const row = page.locator("#acquisition-" + acquisition);
  await row.getByText(/Synthetic anterior site/).waitFor();
  await row.getByText(new RegExp("Clinical decision: " + review)).waitFor();

  const audio = row.locator("audio[src*='/segment/audio/']").first();
  const source = await audio.getAttribute("src");
  const wav = await page.request.get(new URL(source, page.url()).href);
  assert.equal(wav.status(), 200);
  const bytes = await wav.body();
  assert.equal(bytes.subarray(0, 4).toString(), "RIFF");
  assert.ok(bytes.length > 44);

  const ecg = await row.locator('a[href*="/segment/ecg/"]').first().getAttribute("href");
  const svg = await page.request.get(new URL(ecg, page.url()).href);
  assert.equal(svg.status(), 200);
  assert.match(await svg.text(), /Verified synthetic source segment/);

  if (review === "partial") {
    await row.getByText("source_gap: samples 1920–2020").waitFor();
    await row.getByLabel("Audio sample").fill("1930");
    await row.getByRole("button", { name: "Find corresponding ECG ranges" }).click();
    await row.getByText("Clock alignment unavailable; no correspondence inferred").waitFor();
  } else {
    await row.getByText("Clock mapping: bounded. Source uncertainty remains part of the evidence.", { exact: true }).first().waitFor();
    await row.getByLabel("Audio sample").fill("48");
    await row.getByRole("button", { name: "Find corresponding ECG ranges" }).click();
    await row.getByText(/^Possible ECG ranges: \d+–\d+(?:, \d+–\d+)*$/).waitFor();
  }
} finally {
  await browser.close();
}
