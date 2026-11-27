import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import test from "node:test";
import vm from "node:vm";

test("workspace Mermaid renders every ExDoc page load using the current theme", () => {
  const hook = readFileSync(new URL("../build_support/docs_hook.html", import.meta.url), "utf8");
  const script = hook.match(/<script>([\s\S]*?)<\/script>/)[1];
  const listeners = new Map();
  const rendered = [];
  const themes = [];
  const replacements = [];
  let dark = false;
  let blocks = [];
  const listen = (name, callback) => listeners.set(name, callback);
  const mermaid = {
    initialize: options => themes.push(options.theme),
    run: ({nodes}) => rendered.push(nodes),
  };
  const document = {
    addEventListener: listen,
    body: {classList: {contains: name => name === "dark" && dark}},
    querySelectorAll: selector => {
      assert.equal(selector, "pre code.mermaid");
      return blocks;
    },
    createElement: name => {
      assert.equal(name, "div");
      return {};
    },
  };

  vm.runInNewContext(script, {document, mermaid, window: {mermaid, addEventListener: listen}});

  for (const [source, theme] of [["flowchart TD; A --> B", "default"], ["flowchart TD; C --> D", "dark"]]) {
    dark = theme === "dark";
    blocks = [{textContent: source, parentElement: {replaceWith: node => replacements.push(node)}}];
    listeners.get("exdoc:loaded")?.();
    assert.equal(replacements.at(-1)?.textContent, source);
    assert.equal(replacements.at(-1)?.className, "mermaid");
    assert.equal(themes.at(-1), theme);
    assert.equal(rendered.at(-1)?.[0], replacements.at(-1));
  }

  assert.equal(rendered.length, 2);
  blocks = [];
  listeners.get("exdoc:loaded")?.();
  assert.equal(rendered.length, 2);
});
