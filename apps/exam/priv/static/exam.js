import { Socket } from "/assets/phoenix.mjs";
import { LiveSocket } from "/assets/phoenix_live_view.esm.js";
import { createMedExHook } from "/med_ex/session_hook.js";

import { startPCM } from "/med_ex/pcm_capture.js";

async function rtcConfig(element) {
  const encounter = element.dataset.encounter || element.dataset.encounterId;
  const response = await fetch(`/encounters/${encodeURIComponent(encounter)}/ice`, {
    headers: {Accept: "application/json"}, cache: "no-store"
  });
  if (!response.ok) throw new Error("Media configuration unavailable");
  return response.json();
}

async function listInputs(select) {
  try {
    const devices = await navigator.mediaDevices.enumerateDevices();
    const selected = select.value;
    select.replaceChildren(new Option("System default", ""));
    for (const item of devices.filter(d => d.kind === "audioinput" && d.deviceId && d.deviceId !== "default")) {
      select.add(new Option(item.label || `Input ${select.length}`, item.deviceId));
    }
    if ([...select.options].some(o => o.value === selected)) select.value = selected;
  } catch {
    // Default input remains available when the browser withholds the device list.
  }
}

const Capture = {
  mounted() {
    const start = this.el.querySelector("[data-start]");
    const finish = this.el.querySelector("[data-finish]");
    const input = this.el.querySelector("[data-input]");
    const status = this.el.querySelector('[role="status"]');
    const base = `/encounters/${encodeURIComponent(this.el.dataset.encounter)}`;
    const savedKey = `med-fabric-attempt${base}`;
    const retry = this.el.querySelector("[data-check]");
    let current;
    this.cleanup = () => { const op = current; current = null; op?.controller?.abort(); op?.socket.close(); };
    void listInputs(input);
    input.onfocus = () => void listInputs(input);

    const readOutcome = async (id, op) => {
      try {
        const res = await fetch(`${base}/attempts/${encodeURIComponent(id)}`, {headers: {Accept: "application/json"}, cache: "no-store"});
        if (!res.ok) throw new Error();
        const {status: saved} = await res.json();
        if (current !== op || !this.el.isConnected) return;
        status.textContent = saved;
        retry.hidden = saved !== "recording";
        if (saved !== "recording") sessionStorage.removeItem(savedKey);
        else status.textContent = "Recording outcome pending";
      } catch {
        if (current === op && this.el.isConnected) {
          status.textContent = "Recording outcome unavailable";
          retry.hidden = false;
        }
      }
    };
    retry.onclick = () => {
      const id = sessionStorage.getItem(savedKey);
      if (id) void readOutcome(id, current);
    };
    const prior = sessionStorage.getItem(savedKey);
    if (prior) void readOutcome(prior, current);

    start.onclick = async () => {
      retry.hidden = true;
      start.disabled = true;
      input.disabled = true;
      status.textContent = "Starting microphone";
      const url = new URL(base + "/pcm", location.href);
      url.protocol = location.protocol === "https:" ? "wss:" : "ws:";
      const socket = new WebSocket(url);
      const op = current = {socket};
      const outcome = (result, metrics) => {
        if (current !== op) return;
        if (metrics) this.el.dataset.transport = JSON.stringify(metrics);
        status.textContent = result;
        start.disabled = input.disabled = false;
        finish.disabled = true;
        if (result === "ready") sessionStorage.removeItem(savedKey);
        else if (op.id && ["disconnected", "capture_failed"].includes(result)) void readOutcome(op.id, op);
      };

      try {
        op.id = await new Promise((resolve, reject) => {
          socket.onmessage = ({data}) => {
            try {
              const {acquisition_id: id} = JSON.parse(data);
              if (typeof id !== "string" || !id) throw new Error("Missing recording ID");
              resolve(id);
            } catch (error) { reject(error); }
          };
          socket.onerror = reject;
          socket.onclose = reject;
        });
        if (current !== op) return socket.close();
        sessionStorage.setItem(savedKey, op.id);
        const controller = await startPCM(socket, "/med_ex/pcm_worklet.js", outcome, () => {
          if (current === op) { finish.disabled = false; status.textContent = "Recording"; }
        }, {
          deviceId: input.value,
          onSource: settings => socket.send(JSON.stringify({source: settings}))
        });
        if (current === op) op.controller = controller;
        else controller.abort();
      } catch {
        socket.close();
        if (current === op && status.textContent === "Starting microphone") outcome("Capture unavailable");
      }
    };
    finish.onclick = () => { finish.disabled = true; current?.controller?.finish(); };
  },
  destroyed() { this.cleanup(); }
};

async function localSDP(peer, description) {
  await peer.setLocalDescription(description);
  if (peer.iceGatheringState !== "complete") {
    await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        peer.removeEventListener("icegatheringstatechange", changed);
        reject(new Error("ICE gathering timed out"));
      }, 5000);
      const changed = () => {
        if (peer.iceGatheringState !== "complete") return;
        clearTimeout(timeout);
        peer.removeEventListener("icegatheringstatechange", changed);
        resolve();
      };
      peer.addEventListener("icegatheringstatechange", changed);
      changed();
    });
  }
  return peer.localDescription.sdp;
}

const Talkback = {
  mounted() {
    const button = this.el.querySelector("button");
    const audio = this.el.querySelector("audio");
    const status = this.el.querySelector('[role="status"]');
    const role = this.el.dataset.role;
    const input = this.el.querySelector("[data-input]");
    void listInputs(input);
    input.onfocus = () => void listInputs(input);

    this.leave = (message = "disconnected") => {
      const call = this.call;
      this.call = null;
      call?.peer?.close();
      this.el.medExPeer = null;
      call?.stream?.getTracks().forEach(track => track.stop());
      call?.socket?.disconnect();
      audio.srcObject = null;
      status.textContent = message;
      button.textContent = "Join conversation";
    };

    button.onclick = async () => {
      if (this.call) return this.leave();
      const call = this.call = {id: crypto.randomUUID()};
      button.textContent = "Leave conversation";

      try {
        const config = await rtcConfig(this.el);
        if (this.call !== call) return;
        const stream = await navigator.mediaDevices.getUserMedia({
          audio: input.value ? {deviceId: {exact: input.value}} : true
        });
        if (this.call !== call) {
          stream.getTracks().forEach(track => track.stop());
          return;
        }
        call.stream = stream;
        const socket = call.socket = new Socket("/socket", {params: {token: this.el.dataset.token}});
        socket.connect();
        const channel = socket.channel("talkback:" + this.el.dataset.encounter, {});
        const send = (type, fields = {}) => channel.push("signal", {type, id: call.id, ...fields});
        const current = peer => this.call === call && call.peer === peer;
        const reset = () => {
          call.peer?.close();
          audio.srcObject = null;
          const peer = call.peer = new RTCPeerConnection(config);
          this.el.medExPeer = peer;
          stream.getAudioTracks().forEach(track => peer.addTrack(track, stream));
          peer.ontrack = ({streams}) => { if (current(peer)) audio.srcObject = streams[0]; };
          peer.onconnectionstatechange = () => {
            if (current(peer)) status.textContent = peer.connectionState;
          };
          return peer;
        };

        channel.on("signal", async signal => {
          if (this.call !== call || signal.role === role) return;
          let peer;
          try {
            if (signal.type === "ready" && role === "patient") send("ready");
            if (signal.type === "ready" && role === "clinician" && call.remote !== signal.id) {
              call.remote = signal.id;
              const offer = call.offer = crypto.randomUUID();
              peer = reset();
              const sdp = await localSDP(peer, await peer.createOffer());
              if (current(peer)) send("offer", {offer, target: signal.id, sdp});
            }
            if (signal.type === "offer" && role === "patient" && signal.target === call.id && signal.offer !== call.offer) {
              call.offer = signal.offer;
              peer = reset();
              await peer.setRemoteDescription({type: "offer", sdp: signal.sdp});
              if (!current(peer)) return;
              const sdp = await localSDP(peer, await peer.createAnswer());
              if (current(peer)) send("answer", {offer: signal.offer, target: signal.id, sdp});
            }
            if (signal.type === "answer" && role === "clinician" && signal.target === call.id &&
                signal.offer === call.offer && signal.id === call.remote) {
              peer = call.peer;
              if (peer.signalingState === "have-local-offer") {
                await peer.setRemoteDescription({type: "answer", sdp: signal.sdp});
              }
            }
          } catch {
            if (peer && current(peer)) this.leave("Conversation negotiation failed");
          }
        });
        const unavailable = () => { if (this.call === call) this.leave("Conversation unavailable"); };
        channel.onError(unavailable);
        channel.onClose(unavailable);
        channel.join().receive("ok", () => send("ready"))
          .receive("error", unavailable).receive("timeout", unavailable);
      } catch {
        if (this.call === call) this.leave("Microphone unavailable");
      }
    };
  },
  destroyed() {
    this.leave();
  }
};

const csrfToken = document.querySelector('meta[name="csrf-token"]').content;
const liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
  hooks: {
    DeviceMonitor: {
      mounted() {
        const audio = this.el.querySelector("audio");
        const output = this.el.querySelector("output");
        this.request = async (operation, data = {}) => {
          const response = await fetch(this.el.dataset.endpoint, {method: "POST", headers: {
            "content-type": "application/json", "x-csrf-token": document.querySelector("meta[name=csrf-token]").content
          }, body: JSON.stringify({operation, ...data})});
          if (!response.ok) throw new Error("Preview unavailable");
          return response.json();
        };
        this.el.querySelector("button").onclick = async () => {
          try {
            this.peer?.close();
            const ice = await fetch(this.el.dataset.endpoint.split("/devices/")[0] + "/ice").then(r => r.json());
            this.peer = new RTCPeerConnection(ice);
            this.peer.addTransceiver("audio", {direction: "recvonly"});
            this.peer.ontrack = e => {audio.srcObject = new MediaStream([e.track]); audio.play().catch(() => {});};
            await this.peer.setLocalDescription(await this.peer.createOffer());
            await new Promise((resolve, reject) => {
              const timer = setTimeout(() => reject(new Error("ICE gathering timeout")), 6000);
              const check = () => {if (this.peer.iceGatheringState === "complete") {clearTimeout(timer);resolve();}};
              this.peer.onicegatheringstatechange = check; check();
            });
            const answer = await this.request("offer", {sdp: this.peer.localDescription.sdp});
            await this.peer.setRemoteDescription({type: "answer", sdp: answer.sdp});
            clearInterval(this.timer);
            this.timer = setInterval(() => this.request("status").then(s => output.textContent = s.state).catch(() => output.textContent = "Disconnected"), 2000);
          } catch (error) { output.textContent = error.message; this.peer?.close(); }
        };
      },
      destroyed() {clearInterval(this.timer);this.peer?.close();this.request("close").catch(() => {});}
    },
    Capture,
    Talkback,
    MedExSessionHook: createMedExHook({
      Socket, rtcConfig,
      socketPath: "/socket",
      topic: el => "signaling:" + el.dataset.encounterId,
      play: "#preview-play",
      disconnect: "#preview-disconnect",
      reconnect: "#preview-reconnect"
    })
  }
});

liveSocket.connect();
