import test from "node:test";
import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
import {createHash,webcrypto} from "node:crypto";
import vm from "node:vm";
import {fileURLToPath} from "node:url";
const asset=new URL("../priv/static/acquisition.js",import.meta.url);
const module=await import("data:text/javascript;base64,"+Buffer.from(await readFile(asset)).toString("base64"));
const {parseJSON,parseReceipt,observe,committedSuccessor,exactPrefix,handoff,frameHeader,BrowserAcquisition}=module;
if(!globalThis.crypto)Object.defineProperty(globalThis,"crypto",{value:webcrypto});
const path=process.env.MEDEX_RECEIPT_VECTORS||fileURLToPath(new URL("../../../../med_ex/core/med_core/test/fixtures/receipt_vectors_v2.json",import.meta.url));
const corpusBytes=await readFile(path);
assert.equal(createHash("sha256").update(corpusBytes).digest("hex"),"00e4b87285b26e995f5f0e3bff01c3cce5a8f3c4701e41d9f3981b73a197901b");
const corpus=JSON.parse(corpusBytes);
assert.equal(corpus.cases.length,51);
for(const vector of corpus.cases)test("shared receipt corpus: "+vector.id,()=>{
  let actual;
  try {
    switch(vector.operation){
      case "parse":parseReceipt(vector.proposed);actual="ok";break;
      case "observe":observe(vector.previous,vector.proposed);actual="ok";break;
      case "commit":committedSuccessor(vector.previous,vector.proposed,vector.planned_cursor);actual="ok";break;
      case "exact":actual=String(exactPrefix(vector.previous,vector.proposed));break;
      case "handoff":handoff(vector.previous,vector.proposed,vector.binding);actual="ok";break;
      default:throw new Error("Unknown corpus operation");
    }
  } catch(error){actual=error.code||error.message;}
  assert.equal(actual,vector.expected);
});
const base=corpus.cases[0].previous;
const receipt=(q,n,g="3")=>({...base,accepted_sequence:String(q),durable_sequence:String(q),accepted_sample:String(n),durable_sample:String(n),journal_generation:g,journal_digest:"c".repeat(64)});
const zero={...base,accepted_sequence:"0",durable_sequence:"0",accepted_sample:"0",durable_sample:"0",journal_generation:"1"};
function acquisition(){const a=new BrowserAcquisition({encounter:"e",csrf:"test"});a.receipt=zero;a.authorityDeadline=performance.now()+30000;a.frames=15;a.bytes=262144;return a;}
function entry(q,first,count=960){return {sequence:String(q),first:String(first),count,buffer:new ArrayBuffer(1968),sent:true};}
test("strict bounded JSON rejects duplicates at every nesting depth and trailing/oversized/inexact data",()=>{
  for(const invalid of ['{"type":"durable","type":"accepted"}','{"receipt":{"fence":"a","fence":"b"}}','{"x":1,"\\u0078":2}','{} {}','{"x":9007199254740993}','{"x":1.0}','['.repeat(20)+'0'+']'.repeat(20),'"'+"a".repeat(16385)+'"'])assert.throws(()=>parseJSON(invalid));
  assert.equal(parseJSON('{"x":[0,true,null,"hello"]}').x[3],"hello");
});
test("coverage validation is atomic even when an ACK contains a real prefix and an uncovered suffix",()=>{
  const a=acquisition();a.pending.set("0",entry(0,0));a.inflight=1;a.inflightBytes=1968;
  const original=a.pending.get("0").buffer;
  assert.throws(()=>a.cover(receipt(2,1920)),/Uncovered/);
  assert.equal(a.pending.size,1);assert.equal(a.pending.get("0").buffer,original);assert.equal(a.inflight,1);assert.equal(a.inflightBytes,1968);
  a.cover(receipt(1,960));assert.equal(a.pending.size,0);assert.equal(a.inflight,0);
});
test("sample-only GAP is explicit coverage and does not infer credit from sequence delta",()=>{
  const a=acquisition();a.gap={first:"0",end:"2000",first_sequence:"0",next_sequence:"0"};
  a.cover(receipt(0,2000));
  assert.throws(()=>acquisition().cover(receipt(0,2000)),/Uncovered/);
});
test("stale connection replies cannot reclaim retained frames or change current receipt",()=>{
  const a=acquisition(),oldSocket={},currentSocket={};a.socket=currentSocket;a.binding={acquisition:"a",generation:"2",connection:"new"};
  a.pending.set("0",entry(0,0));a.message(oldSocket,JSON.stringify({schema:module.SCHEMA,type:"durable",receipt:receipt(1,960),binding:{...a.binding,connection:"old"}}));
  assert.equal(a.pending.size,1);assert.equal(a.receipt,zero);
  a.message(currentSocket,JSON.stringify({schema:module.SCHEMA,type:"durable",receipt:receipt(1,960),binding:{...a.binding,connection:"old"}}));
  assert.equal(a.pending.size,1);assert.equal(a.receipt,zero);
});
test("volatile accepted receipt never grants credit or reclaims a buffer",()=>{
  const a=acquisition();a.socket={};a.binding={acquisition:"a",generation:"1",connection:"c"};a.pending.set("0",entry(0,0));a.inflight=1;
  a.message(a.socket,JSON.stringify({schema:module.SCHEMA,type:"accepted",binding:a.binding,receipt:{...zero,accepted_sequence:"1",accepted_sample:"960"}}));
  assert.equal(a.pending.size,1);assert.equal(a.inflight,1);
});
test("MEX1 counters above 2^53 round trip exactly and overflow refuses before writing",()=>{
  const buffer=new ArrayBuffer(1968),sequence=9007199254740993n,first=sequence+960n;
  const bytes=frameHeader(buffer,4,sequence,first,3);const view=new DataView(bytes.buffer);
  assert.equal(view.getBigUint64(20),sequence);assert.equal(view.getBigUint64(28),first);assert.equal(bytes.byteLength,54);
  assert.throws(()=>frameHeader(buffer,4,0n,(1n<<64n)-1n,1));
});
test("transport buffering and source-record credit are separate finite bounds",()=>{
  globalThis.WebSocket={OPEN:1};const a=acquisition();const sent=[];a.binding={};a.socket={readyState:1,bufferedAmount:0,send:bytes=>sent.push(bytes.length)};
  for(let q=0;q<30;q++)a.pending.set(String(q),entry(q,q*960));for(const e of a.pending.values())e.sent=false;
  a.pump();assert.equal(sent.length,15);assert.equal(a.inflight,15);assert.equal(a.pending.size,30);
  const blocked=acquisition();blocked.binding={};blocked.socket={readyState:1,bufferedAmount:blocked.wsBudget,send:()=>assert.fail("buffer limit ignored")};blocked.pending.set("0",{...entry(0,0),sent:false});blocked.pump();assert.equal(blocked.inflight,0);
});
const workletSource=(await readFile(new URL("../priv/static/acquisition_worklet.js",import.meta.url),"utf8")).replace("export class AcquisitionProcessor","class AcquisitionProcessor");
function worklet(rate,buffers=30){const messages=[];let Type;const context=vm.createContext({sampleRate:rate,AudioWorkletProcessor:class{constructor(){this.port={onmessage:null,postMessage:data=>messages.push(data)};}},registerProcessor:(_,klass)=>Type=klass,ArrayBuffer,DataView,Math,Number,BigInt,Float32Array});vm.runInContext(workletSource,context);const processor=new Type({});for(let i=0;i<buffers;i++)processor.port.onmessage({data:{type:"buffer",buffer:new ArrayBuffer(1968)}});if(buffers===30)processor.port.onmessage({data:{type:"start"}});return {processor,messages};}
function processInput(processor,samples,quantum=128){for(let offset=0;offset<samples.length;offset+=quantum)processor.process([[samples.subarray(offset,offset+quantum)]],[[new Float32Array(Math.min(quantum,samples.length-offset))]]);}
function pcm(messages){return messages.filter(m=>m.type==="frame").flatMap(m=>{const view=new DataView(m.buffer);return Array.from({length:m.count},(_,i)=>view.getInt16(48+i*2,true));});}
test("worklet emits exact real short tail without padding or dropping samples",()=>{
  const {processor,messages}=worklet(48000);const input=Float32Array.from({length:1001},(_,i)=>(i%100)/100-0.5);processInput(processor,input);processor.port.onmessage({data:{type:"finish"}});
  assert.deepEqual(messages.filter(m=>m.type==="frame").map(m=>m.count),[960,41]);assert.equal(pcm(messages).length,1001);
  assert.equal(messages.at(-1).sample,"1001");assert.equal(messages.at(-1).sequence,"2");assert.equal(messages.at(-1).loss,null);
});
test("worklet keeps one resampler phase across quantum boundaries",()=>{
  const input=Float32Array.from({length:4409},(_,i)=>Math.sin(i/13)*0.75);
  const one=worklet(44100),many=worklet(44100);processInput(one.processor,input,4409);processInput(many.processor,input,127);
  one.processor.finish();many.processor.finish();assert.deepEqual(pcm(one.messages),pcm(many.messages));
  assert.equal(pcm(one.messages).length,Math.floor((input.length-1)*48000/44100)+1);
});
test("main-thread stall exhausts only the fixed pool and records one irreversible lost interval",()=>{
  const {processor,messages}=worklet(48000);processInput(processor,new Float32Array(40000));processor.finish();
  assert.equal(messages.filter(m=>m.type==="frame").length,30);assert.equal(messages.filter(m=>m.type==="overflow").length,1);
  assert.equal(messages.at(-1).loss.first,"28800");assert.equal(messages.at(-1).loss.end,"40000");assert.equal(processor.pool.length,0);assert.equal(processor.current,null);assert.equal(messages.at(-1).pool_peak,30);
});
test("producer does not start before its complete pool is admitted",()=>{
  const {processor,messages}=worklet(48000,0);processInput(processor,new Float32Array(128));assert.equal(messages.length,0);assert.equal(processor.sample,0n);
});

test("historical ACK before local invalidation proves coverage but never extends authority",()=>{
  const a=acquisition();a.socket={};a.binding={acquisition:"a",generation:"1",connection:"old"};a.pending.set("0",entry(0,0));a.inflight=1;a.inflightBytes=1968;
  const deadline=a.authorityDeadline;
  a.message(a.socket,JSON.stringify({schema:module.SCHEMA,type:"durable",binding:a.binding,receipt:receipt(1,960)}));
  assert.equal(a.pending.size,0);assert.equal(a.authorityDeadline,deadline);
  a.binding={...a.binding,connection:"new"};a.pending.set("1",entry(1,960));
  a.message(a.socket,JSON.stringify({schema:module.SCHEMA,type:"durable",binding:{...a.binding,connection:"old"},receipt:receipt(2,1920,"4")}));
  assert.equal(a.pending.size,1);assert.equal(a.receipt.durable_sample,"960");
});
test("expired local authority rejects an ACK before any credit or buffer effect",()=>{
  const a=acquisition();a.socket={};a.binding={acquisition:"a",generation:"1",connection:"old"};a.pending.set("0",entry(0,0));a.authorityDeadline=performance.now()-1;
  let denied=0;a.disconnected=()=>denied++;
  a.message(a.socket,JSON.stringify({schema:module.SCHEMA,type:"durable",binding:a.binding,receipt:receipt(1,960)}));
  assert.equal(denied,1);assert.equal(a.pending.size,1);assert.equal(a.receipt,zero);
  assert.throws(()=>a.grant(30000,performance.now()-31000),/delayed/);
});
test("stale heartbeat cannot renew authority before its full connection binding is checked",()=>{
  const a=acquisition();a.socket={};a.binding={acquisition:"a",profile:"browser_microphone",generation:"2",connection:"current"};
  const deadline=a.authorityDeadline,waiter={type:"heartbeat",nonce:"n",started:performance.now(),resolve:()=>assert.fail("stale reply resolved")};
  a.waiters.set("heartbeat",waiter);
  a.message(a.socket,JSON.stringify({schema:module.SCHEMA,type:"heartbeat_reply",operation_id:"heartbeat",binding:{...a.binding,connection:"old"},nonce:"n",boot:a.page,generation:"2",remaining_ms:30000}));
  assert.equal(a.authorityDeadline,deadline);assert.equal(a.waiters.get("heartbeat"),waiter);assert.equal(a.authorityTimer,null);
});
test("malformed Unicode is rejected in strict JSON and receipt identity strings",()=>{
  assert.throws(()=>parseJSON('{"fence":"\\ud800"}'),/Unicode/);
  assert.throws(()=>parseReceipt({...zero,journal_id:"\ud800"}),/invalid_receipt/);
});
