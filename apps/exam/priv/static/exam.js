import { Socket } from "/assets/phoenix.mjs";
import { LiveSocket } from "/assets/phoenix_live_view.esm.js";
import { createMedExHook } from "/med_ex/session_hook.js";

import { startPCM } from "/med_ex/pcm_capture.js";

const Capture = {
  mounted() {
    const start = this.el.querySelector("[data-start]");
    const finish = this.el.querySelector("[data-finish]");
    const status = this.el.querySelector('[role="status"]');
    start.onclick = async () => {
      start.disabled = true;
      const url = new URL("/pcm", location.href);
      url.protocol = location.protocol === "https:" ? "wss:" : "ws:";
      const socket = new WebSocket(url);
      this.socket = socket;

      const outcome = result => {
        status.textContent = result;
        start.disabled = false;
        finish.disabled = true;
      };

      try {
        await new Promise((resolve, reject) => {
          socket.onopen = resolve;
          socket.onerror = reject;
          socket.onclose = reject;
        });
        this.capture = await startPCM(socket, "/med_ex/pcm_worklet.js", outcome);
        finish.disabled = false;
        status.textContent = "Recording";
      } catch {
        socket.close();
        outcome("Capture unavailable");
      }
    };
    finish.onclick = () => {
      finish.disabled = true;
      this.capture?.finish();
    };
  },
  destroyed() {
    this.capture?.abort();
    this.socket?.close();
  }
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

    this.leave = (message = "disconnected") => {
      const call = this.call;
      this.call = null;
      call?.peer?.close();
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
        const stream = await navigator.mediaDevices.getUserMedia({audio: true});
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
          const peer = call.peer = new RTCPeerConnection();
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
    Capture,
    Talkback,
    MedExSessionHook: createMedExHook({
      Socket,
      socketPath: "/socket",
      topic: el => "signaling:" + el.dataset.encounterId,
      play: "#preview-play",
      disconnect: "#preview-disconnect",
      reconnect: "#preview-reconnect"
    })
  }
});

liveSocket.connect();
