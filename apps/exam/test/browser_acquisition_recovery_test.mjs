import test from "node:test";
import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
import {createHash} from "node:crypto";
import vm from "node:vm";

const source = await readFile(new URL("../priv/static/acquisition.js", import.meta.url), "utf8");
const sha = bytes => createHash("sha256").update(bytes).digest("hex");
const clone = value => JSON.parse(JSON.stringify(value));

class Clock {
  now = 0;
  id = 0;
  timers = new Map();
  set(callback, delay, interval = false) {
    const id = ++this.id;
    this.timers.set(id, {callback, at: this.now + delay, interval: interval ? delay : 0});
    return id;
  }
  async flush() { for (let n = 0; n < 40; n++) await Promise.resolve(); }
  async advance(ms) {
    const end = this.now + ms;
    for (let count = 0; count < 20000; count++) {
      await this.flush();
      const next = [...this.timers].sort((a, b) => a[1].at - b[1].at)[0];
      if (!next || next[1].at > end) { this.now = end; await this.flush(); return; }
      const [id, timer] = next;
      this.now = timer.at;
      if (timer.interval) timer.at += timer.interval;
      else this.timers.delete(id);
      timer.callback();
    }
    assert.fail("unbounded timer loop");
  }
  async until(predicate, bound = 40000) {
    const end = this.now + bound;
    for (let n = 0; n < 20000; n++) {
      await this.flush();
      if (predicate()) return;
      const next = Math.min(...[...this.timers.values()].map(t => t.at));
      assert.ok(next <= end, "operation did not settle within its bound");
      await this.advance(Math.max(0, next - this.now));
    }
    assert.fail("unbounded operation loop");
  }
  async result(promise) {
    let outcome;
    promise.then(value => { outcome = {value}; }, error => { outcome = {error}; });
    await this.until(() => outcome);
    if (outcome.error) throw outcome.error;
    return outcome.value;
  }
}

// This transport models the existing host's admission, volatile acceptance,
// durable checkpoints, journal handoff, terminal recovery and idempotent seal.
// Tests inspect actual client envelopes/bytes and state; no client method is mocked.
function harness(options = {}) {
  const clock = new Clock();
  const statuses = [], sockets = [], posts = [], requests = [], frames = [], hashes = [], mediaReady = [];
  const effects = {frames: [], gaps: [], terminals: 0, seals: 0};
  let receipt, volatile = [], terminal = null, currentBinding, serial = 0, client;
  const faults = (options.faults || []).map(fault => ({...fault, used: false}));
  const producer = {sequence: 0n, sample: 0n, buffers: [], finish: 0, starts: 0, trackStops: 0, closes: 0, disconnects: 0};
  const commit = () => {
    if (!volatile.length) return;
    for (const item of volatile) {
      if (item.kind === "frame") effects.frames.push(item.bytes);
      else effects.gaps.push(item.gap);
      receipt.accepted_sequence = receipt.durable_sequence = item.sequence;
      receipt.accepted_sample = receipt.durable_sample = item.sample;
    }
    receipt.journal_generation = String(BigInt(receipt.journal_generation) + 1n);
    receipt.journal_digest = sha("checkpoint-" + ++serial);
    volatile = [];
  };
  const acceptedReceipt = () => {
    const last = volatile.at(-1);
    return {...receipt, ...(last ? {accepted_sequence: last.sequence, accepted_sample: last.sample} : {})};
  };
  const deliver = (socket, message) => queueMicrotask(() => socket.onmessage?.({data: JSON.stringify(message)}));
  const handle = (socket, raw) => {
    const binary = typeof raw !== "string";
    const bytes = binary ? Buffer.from(raw) : null;
    const header = binary ? new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength) : null;
    const sequence = binary ? String(header.getBigUint64(20)) : null;
    const first = binary ? String(header.getBigUint64(28)) : null;
    const msg = binary ? {type: "frame", operation_id: `frame-${sequence}-${first}`} : JSON.parse(raw);
    const item = {socket, msg, ...(binary ? {bytes} : {})};
    requests.push(item);
    if (binary) frames.push(item);
    const fault = faults.find(f => !f.used && f.type === msg.type);
    if (fault) fault.used = true;
    if (fault?.action === "dropBefore") { socket.drop(); return; }
    if (fault?.action === "hold") return;
    let result = {schema: "medex.acquisition.v2", operation_id: msg.operation_id, binding: currentBinding};
    if (fault?.action === "refuse") {
      result = {...result, type: "refused", reason: msg.type === "finish" ? "durable_drain_required" : "not_committed", retry: true,
        ...(binary ? {transport_sha256: sha(bytes)} : msg.type === "gap" ? {fingerprint: sha(client.canonical(gapFields(msg)))} : {})};
    } else if (msg.type === "hello") {
      currentBinding = {acquisition: "acquisition", profile: "browser_microphone", generation: String(socket.number), connection: "control-" + socket.number};
      result = {...result, type: "admitted", binding: currentBinding, api_revision: 2, lease: "lease_0123456789abcdef", authority_ms: 30000,
        credit_frames: options.creditFrames || 15, credit_bytes: options.creditBytes || 262144, phase: effects.seals ? "sealed" : "capturing"};
    } else if (msg.type === "open_stream") {
      const previous = receipt && clone(receipt);
      volatile = [];
      if (!terminal) receipt = {stream_id: "audio", source_epoch: String(client.a.epoch), descriptor_ref: msg.descriptor_ref,
        fence: "fence-" + socket.number, journal_id: "journal-" + socket.number, journal_generation: "1", journal_digest: sha("open-" + socket.number),
        accepted_sequence: previous?.durable_sequence || "0", durable_sequence: previous?.durable_sequence || "0",
        accepted_sample: previous?.durable_sample || "0", durable_sample: previous?.durable_sample || "0"};
      currentBinding = {...currentBinding, connection: "stream-" + socket.number, stream: "audio", fence: receipt.fence, journal_id: receipt.journal_id};
      result = {...result, type: terminal ? "stream_finished" : "durable", binding: currentBinding, receipt: clone(receipt),
        credit_frames: options.creditFrames || 15, credit_bytes: options.creditBytes || 262144,
        ...(terminal || {}), ...(previous && !terminal ? {handoff: {asserted_by: "authenticated_host", previous, successor: clone(receipt), imported: previous}} : {})};
    } else if (binary) {
      volatile.push({kind: "frame", bytes, sequence: String(BigInt(sequence) + 1n), sample: String(BigInt(first) + BigInt(header.getUint32(36)))});
      result = {...result, type: "accepted", receipt: acceptedReceipt(), transport_sha256: sha(bytes)};
    } else if (msg.type === "gap") {
      const gap = gapFields(msg);
      volatile.push({kind: "gap", gap, sequence: gap.next_sequence, sample: gap.end});
      if (fault?.action === "dropAfter") commit();
      result = {...result, type: "accepted", receipt: acceptedReceipt(), fingerprint: sha(client.canonical(gap))};
    } else if (msg.type === "checkpoint") {
      commit();
      result = {...result, type: "durable", receipt: clone(receipt)};
    } else if (msg.type === "finish") {
      assert.equal(volatile.length, 0, "finish sent before durable drain");
      assert.equal(msg.sequence, receipt.durable_sequence);
      assert.equal(msg.sample, receipt.durable_sample);
      receipt.journal_generation = String(BigInt(receipt.journal_generation) + 1n);
      receipt.journal_digest = sha("terminal-" + ++serial);
      terminal = {index_digest: sha("terminal-index"), terminal: msg.interruption ? "interrupted" : "finished"};
      effects.terminals++;
      result = {...result, type: "stream_finished", receipt: clone(receipt), ...terminal};
    } else if (msg.type === "finish_acquisition") {
      assert.ok(terminal, "manifest attempted before terminal proof");
      effects.seals = 1;
      result = {...result, type: "sealed", digest: sha("manifest")};
    } else if (msg.type === "heartbeat") {
      result = {...result, type: "heartbeat_reply", nonce: msg.nonce, boot: client.a.page, generation: currentBinding.generation, remaining_ms: 30000};
    } else assert.fail("unexpected request " + msg.type);
    if (fault?.action === "dropAfter") socket.drop();
    else deliver(socket, fault?.mutate ? fault.mutate(result, item) : result);
  };
  class Socket {
    static OPEN = 1;
    readyState = 0;
    bufferedAmount = 0;
    constructor(url) { this.url = String(url); this.number = sockets.push(this); queueMicrotask(() => { if (this.readyState === 0) { this.readyState = 1; this.onopen?.(); } }); }
    send(raw) { assert.equal(this.readyState, 1, "send to closed socket"); handle(this, raw); }
    close() { if (this.readyState === 3) return; this.readyState = 3; queueMicrotask(() => this.onclose?.()); }
    drop() { this.close(); }
  }
  const track = {stop: () => producer.trackStops++, getSettings: () => ({sampleRate: 48000, channelCount: 1})};
  const context = vm.createContext({
    ArrayBuffer, Uint8Array, Uint32Array, DataView, TextEncoder, URL, AbortController, queueMicrotask,
    crypto: {randomUUID: () => "nonce-" + ++serial, getRandomValues: values => { values[0] = 7; return values; },
      subtle: {digest: async (_algorithm, input) => {
        const result = Uint8Array.from(createHash("sha256").update(input).digest()).buffer;
        if (options.holdFrameHash && input.byteLength >= 48 && new DataView(input.buffer, input.byteOffset, input.byteLength).getUint32(0) === 0x4d455831)
          return new Promise(resolve => hashes.push(() => resolve(result)));
        return result;
      }}},
    performance: {now: () => clock.now},
    setTimeout: (fn, ms) => clock.set(fn, ms), clearTimeout: id => clock.timers.delete(id),
    setInterval: (fn, ms) => clock.set(fn, ms, true), clearInterval: id => clock.timers.delete(id),
    location: {href: "https://example.test/encounters/e", protocol: "https:"}, WebSocket: Socket,
    navigator: {mediaDevices: {getUserMedia: async () => {
      const media = {getTracks: () => [track], getAudioTracks: () => [track]};
      return options.holdMedia ? new Promise(resolve => mediaReady.push(() => resolve(media))) : media;
    }}},
    fetch: async (url, init) => { posts.push({url, ...init}); if (options.holdRenewal && posts.length > 1) return new Promise(() => {}); return {ok: !options.createDenied, json: async () => ({
      acquisition: options.wrongRenewal && posts.length > 1 ? "other" : "acquisition", creation: "creation_0123456789abcdef", source_ref: "source", stream_token: "token-" + posts.length})}; },
    AudioContext: class {
      sampleRate = 48000; state = "suspended"; destination = {}; audioWorklet = {addModule: async () => {}};
      createMediaStreamSource() { return {connect() {}, disconnect: () => producer.disconnects++}; }
      async resume() { this.state = "running"; }
      async close() { producer.closes++; this.state = "closed"; }
    },
    AudioWorkletNode: class {
      port = {onmessage: null, postMessage: data => {
        if (data.type === "buffer") producer.buffers.push(data.buffer);
        if (data.type === "start") producer.starts++;
        if (data.type === "finish") {
          producer.finish++;
          const stopped = () => {
            if (options.tail && producer.finish === 1) client.emit(options.tail);
            this.port.onmessage({data: {type: "stopped", sequence: String(producer.sequence),
              sample: options.loss?.end || String(producer.sample), loss: options.loss || null}});
          };
          if (options.stopDelay) clock.set(stopped, options.stopDelay); else queueMicrotask(stopped);
        }
      }};
      connect() {} disconnect() {}
    }
  });
  vm.runInContext(source.replace(/\bexport (?=(?:async )?function|class|const)/g, "") + "\nthis.exports={BrowserAcquisition,canonical};", context);
  const a = new context.exports.BrowserAcquisition({encounter: "e", csrf: "csrf", status: (state, meta) => statuses.push({state, meta})});
  client = {a, canonical: context.exports.canonical, clock, sockets, posts, requests, frames, producer, effects, statuses, faults, hashes, mediaReady,
    start: () => clock.result(a.start()),
    emit(count = 960) {
      const buffer = producer.buffers.pop();
      assert.ok(buffer, "fixed producer pool exhausted");
      new Uint8Array(buffer, 48, count * 2).fill(Number(producer.sequence % 127n));
      a.fromWorklet({type: "frame", sequence: String(producer.sequence), first: String(producer.sample), count, buffer});
      producer.sequence++; producer.sample += BigInt(count);
      return buffer;
    },
    reply(message, socket = a.socket) { deliver(socket, {schema: "medex.acquisition.v2", binding: clone(currentBinding), ...message}); },
    receipt: () => clone(receipt),
    refuseFrame(frame = frames.at(-1), fields = {}) { client.reply({type: "refused", operation_id: frame.msg.operation_id, reason: "not_committed", retry: true, transport_sha256: sha(frame.bytes), ...fields}, frame.socket); }
  };
  return client;
}
function gapFields(msg) { return Object.fromEntries(["id", "first", "end", "first_sequence", "next_sequence", "irreversible", "cause"].map(key => [key, msg[key]])); }

test("B01 start consumes one creation and reconnect renews the same source identity once", async () => {
  const h = harness(); await h.start();
  assert.equal(h.posts.length, 1);
  assert.equal(h.producer.starts, 1);
  h.sockets[0].drop();
  await h.clock.until(() => h.a.finishPromise);
  assert.equal((await h.clock.result(h.a.finish())).type, "sealed");
  assert.equal(h.posts.length, 2);
  const hellos = h.requests.filter(r => r.msg.type === "hello").map(r => r.msg);
  assert.deepEqual(hellos[1].descriptors, hellos[0].descriptors);
  assert.equal(hellos[1].acquisition, hellos[0].acquisition);
  assert.equal(hellos[1].creation, hellos[0].creation);
});

test("B02 matching frame refusal retains bytes, releases once, backs off and keeps producer alive", async () => {
  const h = harness({faults: [{type: "frame", action: "refuse"}]}); await h.start();
  const original = h.emit(); await h.clock.flush();
  assert.equal(h.a.pending.get("0").buffer, original);
  assert.equal(h.a.inflight, 0); assert.equal(h.a.inflightBytes, 0);
  assert.equal(h.producer.finish, 0); assert.equal(h.producer.trackStops, 0);
  h.refuseFrame(); await h.clock.flush();
  assert.equal(h.a.inflight, 0);
  await h.clock.advance(249); assert.equal(h.frames.length, 1);
  await h.clock.advance(1); assert.equal(h.frames.length, 2);
  assert.deepEqual(h.frames[1].bytes, h.frames[0].bytes);
  assert.equal(h.a.inflight, 1); assert.equal(h.a.pending.size, 1);
  await h.clock.result(h.a.finish());
  assert.equal(h.effects.frames.length, 1); assert.equal(h.effects.terminals, 1);
});

test("B03 duplicate refusal after resend readmits without releasing the new reservation", async () => {
  const h = harness({faults: [{type: "frame", action: "refuse"}]}); await h.start(); h.emit(); await h.clock.flush();
  await h.clock.advance(250); const old = h.frames[0];
  h.refuseFrame(old); await h.clock.flush();
  assert.equal(h.a.inflight, 1, "ambiguous duplicate must not grant credit");
  assert.equal(h.a.pending.size, 1); assert.equal(h.producer.finish, 0);
  await h.clock.advance(1000);
  assert.equal(h.posts.length, 2); assert.equal(h.producer.finish, 0);
  const binding = clone(h.a.binding), before = h.a.inflight;
  h.refuseFrame(old); await h.clock.flush();
  assert.deepEqual(clone(h.a.binding), binding); assert.equal(h.a.inflight, before);
  await h.clock.result(h.a.finish()); assert.equal(h.effects.frames.length, 1);
});

for (const field of ["wrong operation", "wrong digest", "wrong retry flag", "unknown reason"]) test("B03 rejects " + field + " without reclaiming source credit", async () => {
  const changes = {"wrong operation": {operation_id: "frame-9-8640"}, "wrong digest": {transport_sha256: "0".repeat(64)},
    "wrong retry flag": {retry: "true"}, "unknown reason": {reason: "outcome_unknown"}}[field];
  const h = harness({faults: [{type: "frame", action: "hold"}]}); await h.start(); const buffer = h.emit(); await h.clock.flush();
  h.refuseFrame(undefined, changes); await h.clock.flush();
  assert.equal(h.a.pending.get("0").buffer, buffer); assert.equal(h.a.inflight, 1);
  assert.equal(h.a.closed, true); assert.equal(h.effects.seals, 0);
});

for (const partial of [{event_id: "event"}, {fingerprint: "0".repeat(64)}, {event_id: "event", fingerprint: "0".repeat(64)}]) test("B04 hybrid durable envelope cannot reclaim a real prefix: " + Object.keys(partial).join(), async () => {
  const h = harness({faults: [{type: "checkpoint", mutate: msg => ({...msg, ...partial})}]}); await h.start(); h.emit(); await h.clock.flush();
  const promise = h.a.finish();
  await assert.rejects(h.clock.result(promise));
  assert.equal(h.a.pending.size, 1); assert.equal(h.a.inflight, 1); assert.equal(h.effects.seals, 0);
});

test("B05 gap refusal keeps one gap identity and original finish promise until proven durable", async () => {
  const h = harness({loss: {first: "0", end: "37"}, faults: [{type: "gap", action: "refuse"}]}); await h.start();
  const finish = h.a.finish(); assert.equal(h.a.finish(), finish);
  await h.clock.flush();
  assert.equal(h.a.inflight, 0); assert.equal(h.a.gap.end, "37"); assert.equal(h.effects.seals, 0);
  const sealed = await h.clock.result(finish);
  const gaps = h.requests.filter(r => r.msg.type === "gap");
  assert.equal(gaps.length, 2); assert.deepEqual(gapFields(gaps[0].msg), gapFields(gaps[1].msg));
  assert.equal(h.effects.gaps.length, 1); assert.equal(h.effects.terminals, 1); assert.equal(sealed.type, "sealed");
});

test("B05 finish durable-drain refusal checkpoints and retries without stopping twice", async () => {
  const h = harness({faults: [{type: "finish", action: "refuse"}]}); await h.start();
  const finish = h.a.finish(); await h.clock.result(finish);
  assert.equal(h.a.finish(), finish); assert.equal(h.producer.finish, 1);
  const types = h.requests.map(r => r.msg.type);
  assert.deepEqual(types.slice(-4), ["finish", "checkpoint", "finish", "finish_acquisition"]);
  assert.equal(h.effects.terminals, 1); assert.equal(h.effects.seals, 1);
});

test("B05 checkpoint refusal is not invented as a legal noncommit contract", async () => {
  const h = harness({faults: [{type: "checkpoint", action: "refuse"}]}); await h.start(); h.emit(); await h.clock.flush();
  await assert.rejects(h.clock.result(h.a.finish()));
  assert.equal(h.a.pending.size, 1); assert.equal(h.a.inflight, 1); assert.equal(h.effects.seals, 0);
});

for (const phase of ["checkpoint", "gap", "finish", "finish_acquisition"]) for (const action of ["dropBefore", "dropAfter"]) test(`B06 ${phase} ${action} settles original finish through exact recovered proof`, async () => {
  const h = harness({loss: phase === "gap" ? {first: "960", end: "1001"} : null, faults: [{type: phase, action}]}); await h.start(); h.emit(); await h.clock.flush();
  const finish = h.a.finish(); const sealed = await h.clock.result(finish);
  assert.equal(h.a.finish(), finish); assert.equal(sealed.type, "sealed");
  assert.equal(h.producer.finish, 1); assert.equal(h.producer.trackStops, 1); assert.equal(h.producer.closes, 1);
  assert.equal(h.effects.frames.length, 1); assert.equal(h.effects.terminals, 1); assert.equal(h.effects.seals, 1);
  assert.equal(h.posts.length, 2);
  const gaps = h.requests.filter(r => r.msg.type === "gap");
  if (phase === "gap") {
    assert.equal(h.effects.gaps.length, 1);
    assert.equal(new Set(gaps.map(r => r.msg.id)).size, 1);
    assert.equal(gaps.length, action === "dropAfter" ? 1 : 2);
  }
  assert.equal(h.clock.timers.size, 0, "finished client left a timer running");
});

test("B07 concurrent Finish, overflow and socket callbacks stop and emit the real tail once", async () => {
  const h = harness({tail: 41}); await h.start(); h.emit(); await h.clock.flush();
  const finish = h.a.finish();
  h.a.fromWorklet({type: "overflow"}); h.sockets[0].drop(); h.sockets[0].onerror?.();
  const sealed = await h.clock.result(finish);
  assert.equal(h.a.finish(), finish); assert.equal(sealed.type, "sealed"); assert.equal(h.producer.finish, 1);
  assert.deepEqual(h.effects.frames.map(bytes => new DataView(bytes.buffer, bytes.byteOffset).getUint32(36)), [960, 41]);
  assert.equal(h.effects.frames.reduce((n, bytes) => n + (bytes.length - 48) / 2, 0), 1001);
});

test("B08 recovery exhaustion rejects once, preserves retained tail and stops all retries", async () => {
  const h = harness({faults: [{type: "checkpoint", action: "dropBefore"}, ...Array.from({length: 3}, () => ({type: "open_stream", action: "dropBefore"}))]});
  // Arm failed readmissions after the first normal stream open.
  h.faults.filter(f => f.type === "open_stream").forEach(f => { f.used = true; });
  await h.start(); h.faults.filter(f => f.type === "open_stream").forEach(f => { f.used = false; });
  const buffer = h.emit(); await h.clock.flush();
  const finish = h.a.finish(); await assert.rejects(h.clock.result(finish));
  assert.equal(h.a.finish(), finish); assert.equal(h.a.closed, true); assert.equal(h.posts.length, 4);
  assert.equal(h.a.pending.get("0").buffer, buffer); assert.equal(h.a.waiters.size, 0); assert.equal(h.clock.timers.size, 0);
  const sends = h.requests.length; await h.clock.advance(60000); assert.equal(h.requests.length, sends);
});

test("B08 creation failure closes acquired media before any producer starts", async () => {
  const h = harness({createDenied: true}); await assert.rejects(h.start());
  assert.equal(h.producer.starts, 0); assert.equal(h.producer.trackStops, 1); assert.equal(h.producer.closes, 1);
  assert.equal(h.sockets.length, 0); assert.equal(h.clock.timers.size, 0);
});

test("B08 renewal cannot switch acquisition identity", async () => {
  const h = harness({wrongRenewal: true}); await h.start(); h.sockets[0].drop();
  await h.clock.until(() => h.a.finishPromise); await assert.rejects(h.clock.result(h.a.finish()));
  assert.equal(h.requests.filter(r => r.msg.type === "hello").length, 1); assert.equal(h.effects.seals, 0);
});

test("B10 withheld ACKs preserve the fixed pool and exact frame/byte/transport budgets", async () => {
  const h = harness({creditFrames: 3, creditBytes: 3936}); await h.start();
  for (let n = 0; n < 30; n++) h.emit();
  await h.clock.flush();
  assert.equal(h.a.pending.size, 30); assert.equal(h.producer.buffers.length, 0);
  assert.equal(h.a.inflight, 2); assert.equal(h.a.inflightBytes, 3936); assert.equal(h.frames.length, 2);
  h.a.socket.bufferedAmount = h.a.wsBudget;
  const checkpoint = h.a.request("checkpoint"); await h.clock.result(checkpoint);
  assert.equal(h.frames.length, 2); assert.equal(h.a.pending.size, 28);
  h.a.socket.bufferedAmount = 0;
  await h.clock.result(h.a.finish());
  assert.equal(h.effects.frames.length, 30); assert.equal(h.a.inflight, 0); assert.equal(h.a.inflightBytes, 0);
});

test("B03 stale binding refusal cannot release credit or start recovery", async () => {
  const h = harness({faults: [{type: "frame", action: "hold"}]}); await h.start(); h.emit(); await h.clock.flush();
  const binding = clone(h.a.binding), deadline = h.a.authorityDeadline;
  h.refuseFrame(undefined, {binding: {...binding, connection: "obsolete"}}); await h.clock.flush();
  assert.equal(h.a.inflight, 1); assert.equal(h.a.pending.size, 1); assert.deepEqual(clone(h.a.binding), binding);
  assert.equal(h.a.authorityDeadline, deadline); assert.equal(h.posts.length, 1); assert.equal(h.producer.finish, 0);
  h.a.cleanup();
});

test("B04 accepted digest conflict cannot consume source data or frame credit", async () => {
  const h = harness({faults: [{type: "frame", mutate: msg => ({...msg, transport_sha256: "0".repeat(64)})}]}); await h.start();
  const buffer = h.emit(); await h.clock.flush();
  assert.equal(h.a.closed, true); assert.equal(h.a.inflight, 1); assert.equal(h.a.pending.get("0").buffer, buffer);
});

test("B07 cancellation during overlapping drain and recovery backoffs settles without orphaned timers", async () => {
  const h = harness({faults: [{type: "frame", action: "refuse"}, {type: "frame", mutate: msg => {
    queueMicrotask(() => h.refuseFrame(h.frames[0])); return msg;
  }}]});
  await h.start(); h.emit(); await h.clock.flush();
  const finish = h.a.finish(); let outcome;
  finish.then(() => { outcome = "sealed"; }, () => { outcome = "failed"; });
  await h.clock.advance(260); assert.equal(h.a.reconnecting, true);
  h.a.cleanup(); await h.clock.flush();
  assert.equal(outcome, "failed"); assert.equal(h.clock.timers.size, 0);
});

test("B07 disconnect while producer is stopping waits for one real stopped callback", async () => {
  const h = harness({stopDelay: 100, tail: 41}); await h.start(); h.emit(); await h.clock.flush();
  const finish = h.a.finish(); h.sockets[0].drop(); h.sockets[0].onerror?.();
  await h.clock.advance(99); assert.equal(h.producer.finish, 1); assert.equal(h.posts.length, 1);
  await h.clock.result(finish);
  assert.equal(h.effects.frames.length, 2); assert.equal(h.producer.finish, 1); assert.equal(h.producer.closes, 1);
});

test("B08 withheld checkpoint reaches the original drain deadline without inventing noncommit", async () => {
  const h = harness({faults: [{type: "checkpoint", action: "hold"}]}); await h.start(); const buffer = h.emit(); await h.clock.flush();
  const finish = h.a.finish(); await assert.rejects(h.clock.result(finish), /timeout/);
  assert.equal(h.clock.now, 35000); assert.equal(h.a.pending.get("0").buffer, buffer); assert.equal(h.a.inflight, 1);
  assert.equal(h.effects.seals, 0); assert.equal(h.a.waiters.size, 0); assert.equal(h.clock.timers.size, 0);
});

test("B08 authority expiry cannot be renewed by a delayed old heartbeat", async () => {
  const h = harness({faults: [{type: "heartbeat", action: "hold"}, {type: "heartbeat", action: "hold"}]}); await h.start();
  await h.clock.advance(30000); const old = h.sockets[0], oldHeartbeat = h.requests.find(r => r.msg.type === "heartbeat");
  const finish = h.a.finish(); await h.clock.result(finish);
  h.reply({type: "heartbeat_reply", operation_id: oldHeartbeat.msg.operation_id, nonce: oldHeartbeat.msg.nonce,
    boot: h.a.page, generation: "1", remaining_ms: 30000}, old);
  await h.clock.flush(); assert.equal(h.a.authorityDeadline, 0); assert.equal(h.producer.finish, 1); assert.equal(h.posts.length, 2);
});

test("B08 repeated genuine refusals are bounded and retain the uncommitted source", async () => {
  const h = harness({faults: Array.from({length: 12}, () => ({type: "frame", action: "refuse"}))}); await h.start(); const buffer = h.emit();
  await h.clock.until(() => h.a.closed);
  assert.equal(h.a.pending.get("0").buffer, buffer); assert.ok(h.posts.length <= 4); assert.ok(h.frames.length <= 7);
  assert.equal(h.effects.frames.length, 0); assert.equal(h.effects.seals, 0); assert.equal(h.clock.timers.size, 0);
});

test("B09 a malformed recovered terminal never promotes a manifest", async () => {
  const h = harness({faults: [{type: "finish", action: "dropAfter"}, {type: "open_stream", mutate: msg => ({...msg, index_digest: "invalid"})}]});
  h.faults[1].used = true; await h.start(); h.faults[1].used = false;
  await assert.rejects(h.clock.result(h.a.finish()));
  assert.equal(h.effects.terminals, 1); assert.equal(h.effects.seals, 0); assert.equal(h.a.closed, true);
});

test("B10 delayed frame hash cannot send or mutate credit after cleanup", async () => {
  const h = harness({holdFrameHash: true}); await h.start(); const buffer = h.emit(); await h.clock.flush();
  assert.equal(h.frames.length, 0); assert.equal(h.hashes.length, 1);
  h.a.cleanup(); h.hashes[0](); await h.clock.flush();
  assert.equal(h.frames.length, 0); assert.equal(h.a.inflight, 0); assert.equal(h.a.pending.get("0").buffer, buffer);
  assert.equal(h.clock.timers.size, 0);
});

test("B03 a duplicate settled finish refusal cannot fail the next finish attempt", async () => {
  const h = harness({faults: [{type: "finish", action: "refuse", mutate: msg => {
    queueMicrotask(() => h.reply(msg)); return msg;
  }}]}); await h.start();
  const finish = h.a.finish(); await h.clock.result(finish);
  assert.equal(h.effects.terminals, 1); assert.equal(h.effects.seals, 1); assert.equal(h.posts.length, 1);
});

test("B04 a duplicate accepted frame after durable coverage cannot restart or fail capture", async () => {
  const h = harness(); await h.start(); h.emit(); await h.clock.flush();
  const accepted = {...h.receipt(), accepted_sequence: "1", accepted_sample: "960"};
  await h.clock.result(h.a.request("checkpoint"));
  h.reply({type: "accepted", operation_id: "frame-0-0", receipt: accepted, transport_sha256: sha(h.frames[0].bytes)});
  await h.clock.flush();
  assert.equal(h.a.closed, false); assert.equal(h.a.inflight, 0); assert.equal(h.a.pending.size, 0); assert.equal(h.posts.length, 1);
  await h.clock.result(h.a.finish());
});

test("B03 a late gap refusal cannot undo verified durable gap coverage", async () => {
  const h = harness({loss: {first: "0", end: "37"}, faults: [{type: "gap", action: "refuse"}, {type: "finish_acquisition", action: "hold"}]});
  await h.start(); const finish = h.a.finish(); await h.clock.advance(250);
  const gap = h.requests.find(r => r.msg.type === "gap").msg;
  h.reply({type: "refused", operation_id: gap.operation_id, reason: "not_committed", retry: true, fingerprint: sha(h.canonical(gapFields(gap)))});
  await h.clock.flush(); assert.equal(h.a.closed, false); assert.equal(h.a.inflight, 0);
  const seal = h.requests.find(r => r.msg.type === "finish_acquisition").msg;
  h.reply({type: "sealed", operation_id: seal.operation_id, digest: sha("manifest")});
  await h.clock.result(finish); assert.equal(h.effects.gaps.length, 1);
});

test("B03 successful refusal readmission returns the still-running producer to capturing status", async () => {
  const h = harness({faults: [{type: "frame", action: "refuse"}]}); await h.start(); h.emit(); await h.clock.flush();
  await h.clock.advance(250); h.refuseFrame(h.frames[0]); await h.clock.flush(); await h.clock.advance(250);
  assert.equal(h.statuses.at(-1).state, "capturing"); assert.equal(h.producer.finish, 0);
  await h.clock.result(h.a.finish());
});

test("B08 refusal recovery has one bounded deadline even if authority renewal never returns", async () => {
  const h = harness({holdRenewal: true, faults: [{type: "frame", action: "refuse"}]}); await h.start(); const buffer = h.emit(); await h.clock.flush();
  await h.clock.advance(250); h.refuseFrame(h.frames[0]); await h.clock.flush();
  await h.clock.until(() => h.a.closed, 35000);
  assert.equal(h.a.pending.get("0").buffer, buffer); assert.equal(h.producer.trackStops, 1); assert.equal(h.effects.seals, 0);
  assert.equal(h.clock.timers.size, 0); assert.equal(h.a.waiters.size, 0);
});

test("B10 gap waits for transport capacity without consuming credit or losing its identity", async () => {
  const h = harness({loss: {first: "0", end: "37"}}); await h.start(); h.a.socket.bufferedAmount = h.a.wsBudget;
  h.clock.set(() => { h.a.socket.bufferedAmount = 0; }, 100);
  const finish = h.a.finish(); await h.clock.advance(99);
  assert.equal(h.a.inflight, 0); assert.equal(h.requests.filter(r => r.msg.type === "gap").length, 0);
  assert.equal(h.a.closed, false);
  await h.clock.result(finish); assert.equal(h.effects.gaps.length, 1);
});

test("B01 cleanup during microphone permission cannot reopen media or create an acquisition", async () => {
  const h = harness({holdMedia: true}); const start = h.a.start(); await h.clock.flush();
  h.a.cleanup(); h.mediaReady[0]();
  await assert.rejects(h.clock.result(start));
  assert.equal(h.producer.trackStops, 1); assert.equal(h.producer.starts, 0); assert.equal(h.posts.length, 0); assert.equal(h.sockets.length, 0);
});

test("B08 finish after terminal failure preserves the failed status and one rejection", async () => {
  const h = harness(); await h.start(); h.a.fail("interrupted; test failure");
  const count = h.statuses.length, finish = h.a.finish(); await assert.rejects(h.clock.result(finish));
  assert.equal(h.a.finish(), finish); assert.equal(h.statuses.length, count); assert.equal(h.clock.timers.size, 0);
});

test("B10 a delayed source hash follows verified readmission and never sends on the old socket", async () => {
  const h = harness({holdFrameHash: true}); await h.start(); h.emit(); await h.clock.flush();
  h.sockets[0].drop(); await h.clock.advance(250);
  assert.equal(h.posts.length, 2); assert.equal(h.frames.length, 0);
  h.hashes[0](); await h.clock.result(h.a.finish());
  assert.equal(h.frames.length, 1); assert.equal(h.frames[0].socket, h.sockets[1]); assert.equal(h.effects.frames.length, 1);
});
