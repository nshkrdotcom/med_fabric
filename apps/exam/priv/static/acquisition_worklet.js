/* Finite transferable pool. A buffer returns only after durable source coverage.
   No AudioWorklet allocation or postMessage per sample, including main-thread stalls. */
export class AcquisitionProcessor extends AudioWorkletProcessor {
  constructor(options) {
    super();
    this.rate = sampleRate;
    this.pool = [];
    this.current = null;
    this.view = null;
    this.started = false;
    this.used = 0;
    this.sequence = 0n;
    this.sample = 0n;
    this.source = 0;
    this.next = 0;
    this.previous = 0;
    this.first = 0n;
    this.lost = null;
    this.ended = false;
    this.peak = 0;
    this.port.onmessage = ({data}) => {
      if (data.type === "buffer" && data.buffer instanceof ArrayBuffer && data.buffer.byteLength === 1968 && this.pool.length + (this.current ? 1 : 0) < 30) {
        this.pool.push(data.buffer);
        this.peak = Math.max(this.peak, this.pool.length + (this.current ? 1 : 0));
      } else if (data.type === "start" && this.pool.length === 30) this.started = true;
      else if (data.type === "finish") this.finish();
    };
  }
  emit(value) {
    if (this.lost !== null) { this.sample++; return; }
    if (!this.current) {
      this.current = this.pool.pop() || null;
      if (!this.current) {
        this.lost = this.sample;
        this.sample++;
        this.port.postMessage({type: "overflow", first: this.lost.toString()});
        return;
      }
      this.view = new DataView(this.current);
      this.first = this.sample;
      this.used = 0;
    }
    const pcm = this.view;
    const bounded = Number.isFinite(value) ? Math.max(-1, Math.min(1, value)) : 0;
    pcm.setInt16(48 + this.used * 2, Math.round(bounded < 0 ? bounded * 32768 : bounded * 32767), true);
    this.sample++;
    this.used++;
    if (this.used === 960) this.sendFrame();
  }
  sendFrame() {
    if (!this.current || !this.used) return;
    const buffer = this.current;
    this.current = null;
    this.view = null;
    this.port.postMessage({type: "frame", buffer, sequence: this.sequence.toString(), first: this.first.toString(), count: this.used}, [buffer]);
    this.sequence++;
    this.used = 0;
  }
  finish() {
    if (this.ended) return;
    this.ended = true;
    this.sendFrame();
    this.port.postMessage({type: "stopped", sequence: this.sequence.toString(), sample: this.sample.toString(),
      loss: this.lost === null ? null : {first: this.lost.toString(), end: this.sample.toString()},
      source_samples: this.source.toString(), pool_peak: this.peak});
  }
  process(inputs, outputs) {
    for (const channel of outputs[0] || []) channel.fill(0);
    if (this.ended) return false;
    if (!this.started) return true;
    const input = inputs[0]?.[0];
    if (!input) return true;
    for (let index = 0; index < input.length; index++) {
      const value = input[index];
      // Integer phase numerator preserves resampler phase through every quantum.
      while (this.next <= this.source * 48000) {
        const fraction = this.source === 0 ? 1 : (this.next - (this.source - 1) * 48000) / 48000;
        this.emit(this.source === 0 ? value : this.previous + (value - this.previous) * fraction);
        this.next += this.rate;
      }
      this.previous = value;
      this.source++;
    }
    return true;
  }
}
registerProcessor("medfabric-acquisition-v2", AcquisitionProcessor);
