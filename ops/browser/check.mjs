import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { chromium } from "playwright";

const encounter = process.env.MF_EXAM_ID;
const path = `http://127.0.0.1:${process.env.MF_HTTP_PORT}/encounters/${encounter}`;
const browser = await chromium.launch({
  args: ["--use-fake-device-for-media-stream", "--use-fake-ui-for-media-stream"]
});

async function enter(key) {
  const page = await browser.newPage({permissions: ["microphone"]});
  assert.equal((await page.request.get(path)).status(), 403);
  await page.goto(`${path}?key=${encodeURIComponent(key)}`);
  await page.waitForSelector(".phx-connected");
  return page;
}

try {
  const clinician = await enter(process.env.MF_CLINICIAN_ACCESS_KEY);
  if (process.argv.includes("--capture")) {
    const patient = await enter(process.env.MF_PATIENT_ACCESS_KEY);
    await clinician.locator("#talkback button").click();
    await patient.locator("#talkback button").click();
    for (const page of [patient, clinician]) {
      await page.waitForFunction(() => {
        const section = document.querySelector("#talkback");
        return section.querySelector("audio").currentTime > 0.15 &&
          section.querySelector('[role="status"]').textContent === "connected";
      });
    }
    await clinician.locator("#preview-play").click();
    await clinician.waitForFunction(() => document.querySelector("#live-preview").dataset.state === "connected");
    await patient.locator("[data-start]").click();
    await patient.getByText("Recording", {exact: true}).waitFor();
    const audio = async () => {
      const deadline = Date.now() + 10000;
      while (Date.now() < deadline) {
        const decoded = await clinician.evaluate(async () => {
          const peer = document.querySelector("#live-preview").medExPeer;
          if (!peer) return false;
          return Array.from((await peer.getStats()).values()).some(item =>
            item.type === "inbound-rtp" && item.kind === "audio" &&
            item.packetsReceived > 10 && item.totalSamplesReceived > 0);
        });
        if (decoded) return;
        assert.equal(await patient.locator("#capture [role=status]").textContent(), "Recording");
        await new Promise(resolve => setTimeout(resolve, 100));
      }
      assert.fail("No decoded diagnostic audio");
    };
    await audio();
    const first = await clinician.locator("#live-preview").getAttribute("data-connection-id");
    await clinician.locator("#preview-disconnect").click();
    await clinician.locator("#preview-reconnect").click();
    await audio();
    assert.notEqual(await clinician.locator("#live-preview").getAttribute("data-connection-id"), first);
    assert.equal(await patient.locator("#capture [role=status]").textContent(),
      "Recording", "Capture stopped during preview replacement");
    await patient.locator("[data-finish]").click({timeout: 5000});
    await patient.waitForFunction(() => document.querySelector("#capture [role=status]").textContent === "ready");
    await clinician.getByRole("spinbutton").fill("70");
    await clinician.getByRole("button", {name: "Record pulse"}).click();
    await clinician.getByText("70 beats/minute").waitFor();
  }

  const recording = clinician.locator('section[id^="evidence-"]').filter({has: clinician.locator("audio")});
  const recordingUrl = new URL(await recording.locator("audio").getAttribute("src"), path);
  const wavResponse = await clinician.request.get(recordingUrl.href);
  assert.equal(wavResponse.status(), 200);
  const wav = await wavResponse.body();
  assert.equal(wav.toString("ascii", 0, 4), "RIFF");
  assert.equal(wav.readUInt32LE(24), 48000);
  assert.equal(wav.readUInt32LE(40), wav.length - 44);
  assert.ok(wav.length > 19200);

  if (!process.argv.includes("--capture")) {
    for (const row of await clinician.locator('section[id^="evidence-"]').all()) {
      const id = (await row.getAttribute("id")).slice("evidence-".length);
      if (!process.argv.includes("--after-restart")) {
        await row.getByRole("button", {name: "Accept"}).click();
        await row.getByRole("button", {name: "Deliver to FHIR"}).click();
      }

      const remote = row.getByText(/^Observation\//);
      await remote.waitFor();
      const search = new URL(`${process.env.FHIR_BASE_URL.replace(/\/$/, "")}/Observation`);
      search.searchParams.set("identifier", `urn:med-fabric:observation|${encounter}:${id}`);
      const response = await clinician.request.get(search.href, {headers: {Accept: "application/fhir+json"}});
      assert.equal(response.status(), 200);
      const bundle = await response.json();
      assert.equal(bundle.total, 1);
      const evidence = bundle.entry[0].resource;
      assert.equal(`Observation/${evidence.id}`, await remote.textContent());
      if (evidence.valueQuantity) {
        assert.equal(evidence.valueQuantity.value, 70);
        assert.equal(evidence.valueQuantity.code, "/min");
      } else {
        assert.equal(evidence.valueString, createHash("sha256").update(wav).digest("hex"));
      }
    }
  }
  console.log("Verified browser checkpoint", process.argv.at(-1));
} finally {
  await browser.close();
}
