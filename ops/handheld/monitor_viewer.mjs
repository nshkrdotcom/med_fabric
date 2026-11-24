import {readFile,writeFile} from "node:fs/promises";
import {chromium} from "playwright";
const [file,id,ready]=process.argv.slice(2);
const cfg=JSON.parse(await readFile(file,"utf8")),e=cfg.encounters[0];
const root=`http://localhost:${cfg.http_port}/encounters/${e.exam}`;
const b=await chromium.launch({args:["--autoplay-policy=no-user-gesture-required"]});
try{
  const page=await b.newPage();
  await page.goto(root+"?key="+e.clinician_key);
  await page.goto(root+"/devices");
  const view=page.locator("#listen-"+id);
  await view.locator("button").click();
  await page.waitForFunction(id=>{
    const monitor=document.getElementById("listen-"+id);
    const audio=monitor?.querySelector("audio");
    return monitor?.querySelector("output").textContent==="connected" &&
      audio?.srcObject?.getAudioTracks()[0]?.readyState==="live" && audio.currentTime>0.1;
  },id,{timeout:25000});
  await writeFile(ready,"received synthetic monitor audio\n");
  await page.waitForFunction(id=>document.querySelector("#listen-"+id+" output")?.textContent==="Disconnected",id,{timeout:45000});
}finally{await b.close();}
