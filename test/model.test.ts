/**
 * Provider resolution. An Anthropic key means every text call runs on Haiku:
 * no env override, purpose override or OpenAI key may route around it.
 */
import test from "node:test";
import assert from "node:assert/strict";
import { ANTHROPIC_MODEL, modelConfigured, modelName, provider } from "../src/lib/model.js";

const KEYS = ["ANTHROPIC_API_KEY", "OPENAI_API_KEY", "PYAI_API_KEY", "MODEL_PROVIDER", "SUMMARIZER_MODEL"] as const;

function withEnv(env: Partial<Record<(typeof KEYS)[number], string>>, fn: () => void) {
  const saved = Object.fromEntries(KEYS.map((k) => [k, process.env[k]]));
  for (const k of KEYS) delete process.env[k];
  Object.assign(process.env, env);
  try {
    fn();
  } finally {
    for (const k of KEYS) {
      if (saved[k] === undefined) delete process.env[k];
      else process.env[k] = saved[k];
    }
  }
}

test("an Anthropic key wins over OpenAI and PyAI keys, and pins Haiku", () => {
  withEnv({ ANTHROPIC_API_KEY: "sk-ant-x", OPENAI_API_KEY: "sk-x", PYAI_API_KEY: "py-x", SUMMARIZER_MODEL: "gpt-4o" }, () => {
    assert.equal(provider(), "anthropic");
    assert.equal(ANTHROPIC_MODEL, "claude-haiku-5-5");
    assert.equal(modelName(), "claude-haiku-5-5");
    assert.equal(modelName("anthropic", "notes"), "claude-haiku-5-5");
    assert.equal(modelConfigured(), true);
  });
});

test("without an Anthropic key, resolution is unchanged", () => {
  withEnv({ OPENAI_API_KEY: "sk-x" }, () => {
    assert.equal(provider(), "openai");
    assert.equal(modelName(), "gpt-4o-mini");
  });
});
