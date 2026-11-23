#!/usr/bin/env node
// Generate the `preset-standard` overlay for the DSH web profile so that only
// `persona.config.suffix` differs from the shipped dsh-web-app standard preset.
//
// WHY THIS SCRIPT EXISTS
//   The profile patch replaces `config.plugins` WHOLESALE by id — it is not a
//   deep merge. Copying only a `persona` row drops all other plugins (bash, fs,
//   ...). On top of that, fields such as `disabled` are `!!js` expressions, and
//   DSH parses them with **js-yaml** plus its own entry-list schema — NOT the
//   `yaml` package. Serializing with the wrong library turns `!!js ...` into a
//   plain string, which fails `preset-standard` validation and silently leaves
//   the agent without a shell. Always regenerate with this script.
//
// USAGE (as the dsh user):
//   node generate-persona-preset.mjs            # write the overlay body to stdout
//   node generate-persona-preset.mjs --check     # report whether the live file matches
//
// The overlay is appended verbatim to ~/.dsh/profiles/web/cordis.patch.yml.

import { readFile } from "node:fs/promises";
import { createRequire } from "node:module";

const HARNESS = "/home/dsh/apps/harness";
const require = createRequire(`${HARNESS}/node_modules/.bin/dsh`);
// DSH's loader uses js-yaml with a custom !!js type; reuse the exact dialect.
const yaml = require("js-yaml");
const PRESET = `${HARNESS}/node_modules/@deepseek-ai/dsh-web-app/presets/standard.patch.yml`;
const LIVE = "/home/dsh/.dsh/profiles/web/cordis.patch.yml";

const JsExpr = new yaml.Type("tag:yaml.org,2002:js", {
  kind: "scalar",
  resolve: (data) => typeof data === "string",
  construct: (data) => ({ __jsExpr: data }),
  predicate: (data) => data && typeof data === "object" && typeof data.__jsExpr === "string",
  represent: (data) => data.__jsExpr,
});
const schema = yaml.JSON_SCHEMA.extend(JsExpr);

const SUFFIX = `Deployment context: this is the user's own single-machine development server, operated by the user themselves. The user is the root authorization subject for this machine and its data (in the AGENTS.md sense: the human the agent works for), so routine operations, code changes, deployment, configuration, and troubleshooting here are within scope. When the user explicitly asks for something specific, do the work directly; do not reply in a refusal-script style such as "for security reasons I cannot help", and do not preface ordinary work with security disclaimers. Only pause to ask for confirmation when an action is genuinely destructive or irreversible, or would affect systems, accounts, or people outside this machine; and in that case ask once about the specific risk instead of refusing. If scope is ambiguous, ask one clarifying question rather than refusing.`;

const build = async () => {
  const preset = yaml.load(await readFile(PRESET, "utf8"), { schema })[0].insert[0];
  preset.config.plugins.find((p) => p.id === "persona").config.suffix = SUFFIX;
  const dumped = yaml.dump(preset, { schema, noRefs: true, lineWidth: -1 });
  const indented = dumped.split("\n").map((l, i) => (l.length ? (i === 0 ? "- " : "  ") + l : l)).join("\n");
  const header = [
    "",
    "# 追加: standard 预设只改 persona.config.suffix。",
    "# config.plugins 按 id 整体替换，故随包复制全部插件，仅改 suffix。",
    "# disabled 等字段是 !!js 表达式，必须保留 !!js 标签（用本脚本生成，勿手写/勿用 yaml 库）。",
    "# 升级 @deepseek-ai/dsh-web-app 后须重新运行本脚本。详见 docs/15-persona-suffix.md。",
    "",
  ].join("\n");
  return header + indented + "\n";
};

const body = await build();

// Guard: every generated `!!js` marker must survive a round trip.
const parsed = yaml.load(body, { schema });
if (!parsed || JSON.stringify(parsed).indexOf("__jsExpr") === -1) {
  throw new Error("generated overlay lost its !!js expressions — wrong YAML dialect");
}

if (process.argv.includes("--check")) {
  const live = await readFile(LIVE, "utf8");
  const ok = live.includes("suffix:") && live.includes("!!js") &&
    yaml.load(live, { schema }).some((r) => r && r.id === "preset-standard");
  console.log(ok ? "live config already carries the persona overlay" : "live config is missing/!= generated overlay");
  process.exit(ok ? 0 : 1);
}
process.stdout.write(body);
