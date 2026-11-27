export const SCHEMA = "medex.acquisition.v2";
const MAX = (1n << 64n) - 1n;
const keys = ["stream_id","source_epoch","descriptor_ref","fence","journal_id","journal_generation","journal_digest","accepted_sequence","accepted_sample","durable_sequence","durable_sample"];
const counters = ["source_epoch","journal_generation","accepted_sequence","accepted_sample","durable_sequence","durable_sample"];
const hash = /^[0-9a-f]{64}$/;
export function uint(value) {
  if (typeof value !== "string" || !/^(0|[1-9][0-9]{0,19})$/.test(value) || BigInt(value) > MAX) throw new Error("Invalid counter");
  return BigInt(value);
}
export function canonical(value) {
  if (Array.isArray(value)) return "[" + value.map(canonical).join(",") + "]";
  if (value && typeof value === "object") return "{" + Object.keys(value).sort().map(key => JSON.stringify(key)+":"+canonical(value[key])).join(",") + "}";
  if (typeof value === "number" && (!Number.isSafeInteger(value))) throw new Error("Inexact JSON number");
  return JSON.stringify(value);
}
export async function digest(bytes) {
  const input = typeof bytes === "string" ? new TextEncoder().encode(bytes) : bytes;
  return [...new Uint8Array(await crypto.subtle.digest("SHA-256", input))].map(v => v.toString(16).padStart(2,"0")).join("");
}
export function parseJSON(raw) {
  if (typeof raw !== "string" || new TextEncoder().encode(raw).length > 16384) throw new Error("JSON bound");
  let at = 0;
  const space = () => { while (/[ \t\r\n]/.test(raw[at] || "") && at < raw.length) at++; };
  const string = () => {
    const start = at++;
    while (at < raw.length) {
      if (raw[at] === "\\") { at += 2; continue; }
      if (raw[at++] === '"') {
        const decoded=JSON.parse(raw.slice(start,at));
        if(!decoded.isWellFormed())throw new Error("Malformed Unicode");
        return decoded;
      }
    }
    throw new Error("Unterminated string");
  };
  const value = depth => {
    if (depth > 16) throw new Error("JSON depth");
    space();
    if (raw[at] === '"') return string();
    if (raw[at] === "{") {
      at++; space(); const object = Object.create(null); let size = 0;
      if (raw[at] === "}") { at++; return object; }
      do {
        space(); if (raw[at] !== '"') throw new Error("Object key");
        const key = string(); if (Object.hasOwn(object,key) || ++size > 64) throw new Error("Duplicate or excessive object keys");
        space(); if (raw[at++] !== ":") throw new Error("Object colon");
        object[key] = value(depth+1); space();
        const end = raw[at++]; if (end === "}") return object;
        if (end !== ",") throw new Error("Object delimiter");
      } while (at < raw.length);
    }
    if (raw[at] === "[") {
      at++; space(); const array = [];
      if (raw[at] === "]") { at++; return array; }
      do {
        if (array.length >= 256) throw new Error("Array bound");
        array.push(value(depth+1)); space();
        const end = raw[at++]; if (end === "]") return array;
        if (end !== ",") throw new Error("Array delimiter");
      } while (at < raw.length);
    }
    const token = /^(?:true|false|null|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)/.exec(raw.slice(at));
    if (!token) throw new Error("JSON scalar");
    at += token[0].length; const result = JSON.parse(token[0]);
    if (typeof result === "number" && (!Number.isSafeInteger(result) || /[.eE]/.test(token[0]))) throw new Error("Inexact control number");
    return result;
  };
  const result = value(0); space(); if (at !== raw.length) throw new Error("Trailing JSON"); return result;
}
export function exactPrefix(a,b) {
  try { return canonical(parseReceipt(a,true)) === canonical(parseReceipt(b,true)); } catch { return false; }
}
export function committedSuccessor(previous,next,cursor) {
  observe(previous,next);
  if (uint(next.journal_generation) !== uint(previous.journal_generation)+1n ||
      uint(next.durable_sequence) !== uint(String(cursor.next_sequence)) || uint(next.durable_sample) !== uint(String(cursor.next_sample))) receiptError("unexpected_commit");
  return next;
}
export function handoff(previous,next,binding) {
  parseReceipt(previous,true); parseReceipt(next,true);
  if (!binding || binding.authenticated !== true || binding.quiescent !== true || binding.authority !== "authenticated_host" ||
      !exactPrefix(previous,binding.previous) || !exactPrefix(next,binding.successor) || !exactPrefix(previous,binding.imported) ||
      ["stream_id","source_epoch","descriptor_ref"].some(key=>previous[key]!==next[key]) ||
      previous.fence === next.fence || previous.journal_id === next.journal_id || next.journal_generation !== "1" ||
      previous.durable_sequence !== next.durable_sequence || previous.durable_sample !== next.durable_sample) receiptError("unverified_handoff");
  return next;
}
function receiptError(code) { throw Object.assign(new Error(code),{code}); }
export function parseReceipt(value, durable = false) {
  try {
  if (!value || Array.isArray(value) || typeof value !== "object" || Object.keys(value).sort().join() !== [...keys].sort().join()) receiptError("invalid_receipt");
  for (const key of counters) uint(value[key]);
  for (const key of ["descriptor_ref","journal_digest"]) if (!hash.test(value[key])) receiptError("invalid_receipt");
  for (const key of ["stream_id","fence","journal_id"]) if (typeof value[key] !== "string" || !value[key].length || !value[key].isWellFormed() || new TextEncoder().encode(value[key]).length > 256) receiptError("invalid_receipt");
  if (uint(value.source_epoch) > 0xffffffffn || uint(value.journal_generation) < 1n || uint(value.journal_generation) > 100000n || uint(value.accepted_sequence) < uint(value.durable_sequence) || uint(value.accepted_sample) < uint(value.durable_sample)) receiptError("invalid_receipt");
  if (durable && (value.accepted_sequence !== value.durable_sequence || value.accepted_sample !== value.durable_sample)) receiptError("not_durable_receipt");
  return value;
  } catch(error) { if(error.code)throw error; receiptError("invalid_receipt"); }
}
export function observe(previous, next) {
  parseReceipt(previous); parseReceipt(next, true);
  for (const key of ["stream_id","source_epoch","descriptor_ref","fence","journal_id"]) if (previous[key] !== next[key]) receiptError("receipt_identity");
  for (const key of ["durable_sequence","durable_sample","journal_generation"]) if (uint(next[key]) < uint(previous[key])) receiptError("receipt_rollback");
  if (next.journal_generation === previous.journal_generation && ["journal_digest","durable_sequence","durable_sample"].some(key => next[key] !== previous[key])) receiptError("receipt_conflict");
  if (uint(next.journal_generation) > uint(previous.journal_generation) && next.journal_digest === previous.journal_digest) receiptError("receipt_conflict");
  return next;
}
export function frameHeader(buffer, epoch, sequence, first, count, stream = 1, config = 0xffffffff) {
  if (!(buffer instanceof ArrayBuffer) || !Number.isInteger(count) || count < 1 || count * 2 > 65536 || buffer.byteLength < 48 + count * 2) throw new Error("Frame bound");
  const q = uint(String(sequence)), a = uint(String(first));
  if (a + BigInt(count) > MAX || !Number.isInteger(epoch) || epoch < 0 || epoch > 0xffffffff) throw new Error("Frame counter overflow");
  const view = new DataView(buffer);
  view.setUint32(0,0x4d455831); view.setUint8(4,1); view.setUint8(5,0); view.setUint16(6,48);
  view.setUint32(8,stream); view.setUint32(12,epoch); view.setUint32(16,config);
  view.setBigUint64(20,q); view.setBigUint64(28,a); view.setUint32(36,count); view.setUint32(40,count * 2); view.setUint32(44,0);
  return new Uint8Array(buffer,0,48 + count * 2);
}

export class BrowserAcquisition {
  constructor({encounter, deviceId = "", status = () => {}, csrf}) {
    this.encounter = encounter; this.deviceId = deviceId; this.status = status; this.csrf = csrf;
    this.page = crypto.randomUUID(); this.creationRequest = crypto.randomUUID(); this.epoch = crypto.getRandomValues(new Uint32Array(1))[0];
    this.pending = new Map(); this.waiters = new Map(); this.binding = null; this.receipt = null;
    this.inflight = 0; this.inflightBytes = 0; this.produced = null; this.stopping = false; this.closed = false; this.reconnecting = false;
    this.authorityDeadline=0;this.authorityTimer=null;
    this.poolCount = 30; this.wsBudget = 15 * 1968; this.gap = null; this.retryCount = 0;
  }
  async start() {
    this.media = await navigator.mediaDevices.getUserMedia({audio: {channelCount: 1,echoCancellation: false,noiseSuppression: false,autoGainControl: false,...(this.deviceId ? {deviceId: {exact: this.deviceId}} : {})}});
    this.context = new AudioContext({sampleRate: 48000});
    await this.context.audioWorklet.addModule("/assets/acquisition_worklet.js");
    this.created = await this.create();
    this.descriptor = await this.makeDescriptor();
    await this.connect();
    this.worklet = new AudioWorkletNode(this.context,"medfabric-acquisition-v2",{numberOfInputs: 1,numberOfOutputs: 1,outputChannelCount: [1]});
    this.worklet.port.onmessage = ({data}) => this.fromWorklet(data);
    for (let n=0;n<this.poolCount;n++) {
      const buffer = new ArrayBuffer(1968);
      this.worklet.port.postMessage({type: "buffer",buffer},[buffer]);
    }
    this.worklet.port.postMessage({type: "start"});
    this.input = this.context.createMediaStreamSource(this.media);
    this.input.connect(this.worklet); this.worklet.connect(this.context.destination);
    await this.context.resume();
    this.status("capturing",{acquisition: this.created.acquisition});
    this.heartbeat = setInterval(() => this.request("heartbeat",{nonce: crypto.randomUUID()}).catch(() => this.disconnected()),10000);
    return this;
  }
  async create() {
    const response = await fetch(`/encounters/${encodeURIComponent(this.encounter)}/acquisitions/browser`,{method: "POST",cache: "no-store",headers: {"content-type":"application/json","x-csrf-token":this.csrf},body: JSON.stringify({page:this.page,request_id:this.creationRequest})});
    if (!response.ok) throw new Error("Acquisition creation refused");
    return response.json();
  }
  async makeDescriptor() {
    const settings = this.media.getAudioTracks()[0].getSettings();
    const fact=(name,value) => ({name,origin:"observed",value:Number.isInteger(value)?{integer:String(value)}:value});
    const descriptor={schema_version:"1",acquisition_id:this.created.acquisition,source_ref:this.created.source_ref,
      boot_id:this.page,stream_id:"audio",source_epoch:String(this.epoch),modality:"medex:browser_microphone",encoding:"s16le",
      channels:[{id:"mic",label:"microphone",unit:"unknown",calibration:"unknown"}],sample_rate:["48000","1"],layout:"interleaved",clock:"unknown",
      source_processing:[fact("context_sample_rate",this.context.sampleRate),fact("source_sample_rate",settings.sampleRate ?? "unknown"),fact("channel_count",settings.channelCount ?? "unknown"),
        fact("resampler",this.context.sampleRate===48000?"none":"continuous_linear_integer_phase_v1"),fact("echo_cancellation",settings.echoCancellation ?? "unknown"),
        fact("noise_suppression",settings.noiseSuppression ?? "unknown"),fact("auto_gain_control",settings.autoGainControl ?? "unknown"),fact("timing_uncertainty","uncalibrated_browser_clock")],
      capabilities:{encodings:["s16le"],max_frame_samples:"960",max_payload_bytes:"1920",replay:"none",commands:[]}};
    descriptor.descriptor_ref=await digest(canonical(descriptor));
    return descriptor;
  }
  async connect() {
    const created=await this.create();
    const url=new URL(`/encounters/${encodeURIComponent(this.encounter)}/acquisitions/browser/stream`,location.href);
    url.protocol=location.protocol==="https:"?"wss:":"ws:"; url.searchParams.set("token",created.stream_token);
    const socket=this.socket=new WebSocket(url);
    await new Promise((resolve,reject)=>{socket.onopen=resolve;socket.onerror=reject;socket.onclose=reject;});
    socket.onmessage=event=>this.message(socket,event.data);
    socket.onclose=()=>{if(this.socket===socket&&!this.closed)this.disconnected();};
    socket.onerror=()=>{if(this.socket===socket&&!this.closed)this.disconnected();};
    this.binding=null;
    const admitted=await this.request("hello",{api_revision:2,acquisition:created.acquisition,encounter:this.encounter,profile:"browser_microphone",boot:this.page,creation:created.creation,descriptors:{audio:this.descriptor},max_credit_frames:15,max_credit_bytes:262144},true);
    if(admitted.binding?.acquisition!==created.acquisition||admitted.binding?.profile!=="browser_microphone"||
      uint(admitted.binding?.generation)<1n||typeof admitted.binding?.connection!=="string"||!/^[A-Za-z0-9_-]{1,96}$/.test(admitted.binding.connection)||
      Object.keys(admitted.binding).sort().join()!==["acquisition","connection","generation","profile"].join()||
      typeof admitted.lease!=="string"||!/^[A-Za-z0-9_-]{1,96}$/.test(admitted.lease)||
      !Number.isInteger(admitted.credit_frames)||admitted.credit_frames<1||admitted.credit_frames>15||
      !Number.isInteger(admitted.credit_bytes)||admitted.credit_bytes<1||admitted.credit_bytes>262144)throw new Error("Invalid admitted authority");
    this.binding=admitted.binding; this.lease=admitted.lease; this.frames=admitted.credit_frames; this.bytes=admitted.credit_bytes;
    const opened=await this.request("open_stream",{stream:"audio",descriptor_ref:this.descriptor.descriptor_ref,lease:this.lease,max_credit_frames:this.frames,max_credit_bytes:this.bytes},true);
    const previous=this.receipt;
    if(!Number.isInteger(opened.credit_frames)||opened.credit_frames<1||opened.credit_frames>this.frames||
      !Number.isInteger(opened.credit_bytes)||opened.credit_bytes<1||opened.credit_bytes>this.bytes)throw new Error("Invalid stream credit");
    const candidateBinding=opened.binding;
    if(!this.authorityActive()||["acquisition","profile","generation"].some(key=>candidateBinding?.[key]!==admitted.binding?.[key])||candidateBinding.stream!=="audio")throw new Error("Wrong stream authority");
    const receipt=parseReceipt(opened.receipt,true);
    if(receipt.descriptor_ref!==this.descriptor.descriptor_ref||receipt.source_epoch!==String(this.epoch)||receipt.stream_id!=="audio"||receipt.fence!==candidateBinding.fence||receipt.journal_id!==candidateBinding.journal_id)throw new Error("Wrong admitted receipt");
    if(previous&&previous.fence!==receipt.fence){
      const h=opened.handoff;
      if(!h||h.asserted_by!=="authenticated_host")throw new Error("Missing verified handoff");
      observe(previous,parseReceipt(h.previous,true));
      handoff(h.previous,receipt,{authority:"authenticated_host",authenticated:true,quiescent:true,previous:h.previous,successor:h.successor,imported:h.imported});
    }else if(previous)observe(previous,receipt);
    this.cover(receipt);
    this.binding=candidateBinding;this.receipt=receipt;this.frames=opened.credit_frames;this.bytes=opened.credit_bytes;
    this.inflight=0;this.inflightBytes=0;
    for(const entry of this.pending.values())entry.sent=false;
    this.recoveredTerminal = opened.type === "stream_finished" ? opened : null;
    this.pump();
  }
  authorityActive(){return !this.closed&&performance.now()<this.authorityDeadline;}
  grant(remaining,started){
    if(!Number.isInteger(remaining)||remaining<=0||remaining>30000||started+remaining<=performance.now())throw new Error("Invalid or delayed authority");
    this.authorityDeadline=started+remaining;clearTimeout(this.authorityTimer);
    this.authorityTimer=setTimeout(()=>this.disconnected(),Math.max(0,this.authorityDeadline-performance.now()));
  }
  request(type,fields={},allowBindingChange=false) {
    if(type!=="hello"&&!this.authorityActive())return Promise.reject(new Error("Acquisition authority expired"));
    if(!this.socket||this.socket.readyState!==WebSocket.OPEN||this.waiters.size>=4) return Promise.reject(new Error("Transport unavailable"));
    const operation_id=type === "gap" ? "gap-" + fields.id : crypto.randomUUID();
    const envelope={schema:SCHEMA,type,operation_id,...(this.binding?{binding:this.binding}:{}),...fields};
    return new Promise((resolve,reject)=>{
      const timer=setTimeout(()=>{this.waiters.delete(operation_id);reject(new Error("Operation outcome unknown"));},35000);
      this.waiters.set(operation_id,{resolve,reject,timer,allowBindingChange,type,nonce:fields.nonce,started:performance.now()});
      this.socket.send(canonical(envelope));
    });
  }
  message(socket,raw) {
    if(socket!==this.socket||this.closed)return;
    try{
      if(typeof raw!=="string"||raw.length>16384)throw new Error("Invalid reply");
      const msg=parseJSON(raw);if(msg.schema!==SCHEMA)throw new Error("Protocol mismatch");
      const waiter=this.waiters.get(msg.operation_id);
      if(!waiter?.allowBindingChange&&!this.authorityActive())throw new Error("Expired authority");
      if(!waiter?.allowBindingChange&&canonical(msg.binding)!==canonical(this.binding))return;
      if(msg.type==="admitted"){
        if(waiter?.type!=="hello"||msg.api_revision!==2)throw new Error("Unexpected admission");
        this.grant(msg.authority_ms,waiter.started);
      }
      if(msg.type==="heartbeat_reply"){
        if(waiter?.type!=="heartbeat"||msg.nonce!==waiter.nonce||msg.boot!==this.page||msg.generation!==this.binding?.generation)throw new Error("Wrong heartbeat binding");
        this.grant(msg.remaining_ms,waiter.started);
      }
      if(msg.type==="durable"&&msg.receipt&&!waiter?.allowBindingChange){const r=parseReceipt(msg.receipt,true);observe(this.receipt,r);this.cover(r);this.receipt=r;this.pump();}
      if(msg.type==="accepted")parseReceipt(msg.receipt);
      if(msg.type==="refused")throw new Error("Source operation refused");
      if(waiter){clearTimeout(waiter.timer);this.waiters.delete(msg.operation_id);waiter.resolve(msg);}
    }catch{this.disconnected();}
  }
  fromWorklet(data) {
    if(this.closed)return;
    if(data.type==="frame"){
      if(this.pending.size>=this.poolCount) return this.fail("producer_budget_exceeded");
      const entry={...data,sent:false};uint(entry.sequence);uint(entry.first);
      frameHeader(entry.buffer,this.epoch,entry.sequence,entry.first,entry.count);
      this.pending.set(entry.sequence,entry);this.pump();
    } else if(data.type==="overflow") { this.interruption="producer_overflow";this.finish().catch(()=>this.disconnected()); }
    else if(data.type==="stopped") { this.produced=data;this.stoppedResolve?.();this.stoppedResolve=null; }
  }
  cover(receipt) {
    parseReceipt(receipt,true);
    const wantedSequence=uint(receipt.durable_sequence),wantedSample=uint(receipt.durable_sample);
    let sequence=this.receipt?uint(this.receipt.durable_sequence):0n;
    let sample=this.receipt?uint(this.receipt.durable_sample):0n;
    if(wantedSequence<sequence||wantedSample<sample)throw new Error("Coverage rollback");
    const released=[];
    for(const [key,entry] of this.pending){
      const q=uint(key),first=uint(entry.first),end=first+BigInt(entry.count);
      if(q+1n<=wantedSequence&&end<=wantedSample){
        if(q!==sequence||first!==sample)throw new Error("Missing retained coverage");
        sequence=q+1n;sample=end;released.push([key,entry]);
      }
    }
    if(this.gap&&sample===uint(this.gap.first)&&sequence===uint(this.gap.first_sequence)&&
        uint(this.gap.end)<=wantedSample&&uint(this.gap.next_sequence)<=wantedSequence){
      sample=uint(this.gap.end);sequence=uint(this.gap.next_sequence);
    }
    if(sample!==wantedSample||sequence!==wantedSequence)throw new Error("Uncovered durable prefix");
    // Complete receipt/local-source proof precedes every destructive mutation.
    for(const [key,entry] of released){
      this.pending.delete(key);
      if(entry.sent){this.inflight--;this.inflightBytes-=48+entry.count*2;}
      if(this.worklet&&!this.produced)this.worklet.port.postMessage({type:"buffer",buffer:entry.buffer},[entry.buffer]);
    }
    this.drainResolve?.();
  }
  pump(){
    if(!this.binding||!this.authorityActive()||!this.socket||this.socket.readyState!==WebSocket.OPEN||this.reconnecting)return;
    for(const entry of this.pending.values()){
      const bytes=48+entry.count*2;
      if(entry.sent)continue;
      if(this.inflight>=this.frames||this.inflightBytes+bytes>this.bytes||this.socket.bufferedAmount+bytes>this.wsBudget)break;
      entry.sent=true;this.inflight++;this.inflightBytes+=bytes;
      this.socket.send(new Uint8Array(entry.buffer,0,bytes));
    }
  }
  async stopProducer(){
    if(this.produced)return;
    if(!this.worklet)throw new Error("Producer was not admitted");
    this.media?.getTracks().forEach(track=>track.stop());
    await new Promise((resolve,reject)=>{const timer=setTimeout(()=>reject(new Error("Unaccounted producer tail")),5000);this.stoppedResolve=()=>{clearTimeout(timer);resolve();};this.worklet.port.postMessage({type:"finish"});});
    this.input?.disconnect();this.worklet?.disconnect();await this.context?.close();
  }
  async finish(){
    if(this.finishPromise)return this.finishPromise;
    this.stopping=true;this.status("draining",{acquisition:this.created.acquisition});
    this.finishPromise=this.drainAndSeal();return this.finishPromise;
  }
  async drainAndSeal(){
    await this.stopProducer();
    const deadline=performance.now()+35000;
    while(this.pending.size){
      this.pump();
      if(this.inflight>0)await this.request("checkpoint");
      if(performance.now()>deadline)throw new Error("Durable drain timeout");
      await new Promise(resolve=>setTimeout(resolve,10));
    }
    if(this.produced.loss&&this.produced.loss.first!==this.produced.loss.end){
      this.gap={id:crypto.randomUUID(),first:this.produced.loss.first,end:this.produced.loss.end,first_sequence:this.produced.sequence,next_sequence:this.produced.sequence,irreversible:true,cause:"producer_buffer_exhausted"};
      await this.request("gap",this.gap);await this.request("checkpoint");
    }
    const terminal=this.recoveredTerminal || await this.request("finish",{sequence:this.produced.sequence,sample:this.produced.sample,...(this.interruption?{interruption:this.interruption}:{})});
    const receipt=parseReceipt(terminal.receipt,true);
    if(this.recoveredTerminal)observe(this.receipt,receipt);
    else committedSuccessor(this.receipt,receipt,{next_sequence:this.produced.sequence,next_sample:this.produced.sample});
    if(receipt.durable_sequence!==this.produced.sequence||receipt.durable_sample!==this.produced.sample||!hash.test(terminal.index_digest))throw new Error("Terminal coverage mismatch");
    const sealed=await this.request("finish_acquisition");
    if(sealed.type!=="sealed"||!hash.test(sealed.digest))throw new Error("Manifest not promoted");
    this.status("sealed",{acquisition:this.created.acquisition,digest:sealed.digest});this.cleanup();return sealed;
  }
  async disconnected(){
    if(this.closed||this.reconnecting)return;
    this.reconnecting=true;this.binding=null;this.authorityDeadline=0;clearTimeout(this.authorityTimer);
    this.interruption=this.interruption||"transport_lost";
    for(const waiter of this.waiters.values()){clearTimeout(waiter.timer);waiter.reject(new Error("Disconnected; outcome unknown"));}this.waiters.clear();
    clearInterval(this.heartbeat);
    try{
      await this.stopProducer();
      this.socket?.close();
      if(++this.retryCount>3)throw new Error("Recovery attempt bound");
      await new Promise(resolve=>setTimeout(resolve,250));
      await this.connect();this.reconnecting=false;this.finishPromise=null;await this.finish();
    }catch{this.reconnecting=false;this.fail("interrupted; verified prefix preserved");}
  }
  fail(reason){this.status(reason,{acquisition:this.created?.acquisition});this.cleanup();}
  cleanup(){
    this.closed=true;this.authorityDeadline=0;clearTimeout(this.authorityTimer);clearInterval(this.heartbeat);this.socket?.close();this.binding=null;
    this.media?.getTracks().forEach(track=>track.stop());this.input?.disconnect();this.worklet?.disconnect();
    if(this.context?.state!=="closed")this.context?.close().catch(()=>{});
    for(const waiter of this.waiters.values()){clearTimeout(waiter.timer);waiter.reject(new Error("Closed"));}this.waiters.clear();
  }
}
