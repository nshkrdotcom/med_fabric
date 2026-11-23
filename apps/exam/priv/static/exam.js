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
    this.el.querySelector("button").onclick = async event => {
      event.target.disabled = true;
      const status = this.el.querySelector('[role="status"]');
      const role = this.el.dataset.role;
      try {
        const stream = await navigator.mediaDevices.getUserMedia({audio: true});
        this.stream = stream;
        const peer = this.peer = new RTCPeerConnection();
        stream.getAudioTracks().forEach(track => peer.addTrack(track, stream));
        peer.ontrack = ({streams}) => { this.el.querySelector("audio").srcObject = streams[0]; };
        peer.onconnectionstatechange = () => { status.textContent = peer.connectionState; };
        const socket = this.socket = new Socket("/socket", {params: {token: this.el.dataset.token}});
        socket.connect();
        const channel = socket.channel("talkback:" + this.el.dataset.encounter, {});
        const send = (type, sdp) => channel.push("signal", {type, sdp});
        let offered = false;
        channel.on("signal", async signal => {
          if (signal.role === role) return;
          try {
            if (signal.type === "ready" && role === "patient") send("ready");
            if (signal.type === "ready" && role === "clinician" && !offered) {
              offered = true;
              send("offer", await localSDP(peer, await peer.createOffer()));
            }
            if (signal.type === "offer" && role === "patient") {
              await peer.setRemoteDescription({type: "offer", sdp: signal.sdp});
              send("answer", await localSDP(peer, await peer.createAnswer()));
            }
            if (signal.type === "answer" && role === "clinician") {
              await peer.setRemoteDescription({type: "answer", sdp: signal.sdp});
            }
          } catch { status.textContent = "Conversation negotiation failed"; }
        });
        channel.join().receive("ok", () => send("ready"))
          .receive("error", () => { status.textContent = "Conversation unavailable"; });
      } catch { status.textContent = "Microphone unavailable"; }
    };
  },
  destroyed() {
    this.stream?.getTracks().forEach(track => track.stop());
    this.peer?.close();
    this.socket?.disconnect();
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
