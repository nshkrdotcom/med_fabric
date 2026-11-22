import { Socket } from "/assets/phoenix.mjs";
import { LiveSocket } from "/assets/phoenix_live_view.esm.js";
import { createMedExHook } from "/med_ex/session_hook.js";

const csrfToken = document.querySelector('meta[name="csrf-token"]').content;
const liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
  hooks: {
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
