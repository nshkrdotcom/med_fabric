import {readFile} from "node:fs/promises";
import {chromium} from "playwright";
const cfg=JSON.parse(await readFile(process.argv[2],"utf8"));
const encounter=cfg.encounters[0],root=`http://localhost:${cfg.http_port}/encounters/${encounter.exam}`;
const browser=await chromium.launch({args:["--use-fake-ui-for-media-stream","--use-fake-device-for-media-stream"]});
try {
  const patient=await browser.newContext({permissions:["microphone"]});
  const clinician=await browser.newContext({permissions:["microphone"]});
  const p=await patient.newPage(), c=await clinician.newPage();
  await Promise.all([p.goto(root+"?key="+encounter.patient_key),c.goto(root+"?key="+encounter.clinician_key)]);
  await c.locator("#preview-play").click();
  await p.locator("#talkback button").click();
  await c.locator("#talkback button").click();
  await p.locator("[data-start]").click();
  await p.locator("[data-finish]:enabled").waitFor();
  for (const [page,selector] of [[p,"#talkback audio"],[c,"#talkback audio"],[c,"#live-preview audio"]]) {
    await page.waitForFunction(sel=>{
      const el=document.querySelector(sel);
      return el?.srcObject?.getAudioTracks()[0]?.readyState==="live" && el.currentTime>0.1;
    },selector,{timeout:30000});
  }
  await p.locator("[data-finish]").click();
  const playable=c.locator("audio[src*='/recordings/']").first();
  await playable.waitFor({timeout:30000});
  const ok=await playable.evaluate(async e=>{
    const b=await (await fetch(e.src)).arrayBuffer();
    return new TextDecoder().decode(b.slice(0,4))==="RIFF" && b.byteLength>44;
  });
  if(!ok)throw new Error("No verified browser recording");
  await c.locator('input[name="value"]').fill("76");
  await c.getByRole("button",{name:"Record pulse"}).click();
  await c.getByText("76 beats/minute").first().waitFor();
} finally {await browser.close();}
