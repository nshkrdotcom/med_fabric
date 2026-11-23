import {chromium} from "playwright";
import {microphone} from "./microphone.mjs";

const mic = await microphone();
try {
  const server = await chromium.launchServer({
    host: "127.0.0.1", port: Number(process.env.MF_BROWSER_PORT || 9333), args: mic.args
  });
  console.log(server.wsEndpoint());
  for (const signal of ["SIGINT", "SIGTERM"]) process.once(signal, () => void server.close());
  await new Promise(resolve => server.once("close", resolve));
} finally {
  await mic.close();
}
