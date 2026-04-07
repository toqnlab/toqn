import { describe, it, expect, beforeAll, afterAll, beforeEach } from "vitest";
import { execSync } from "child_process";
import fs from "fs";
import path from "path";
import { createMockServer } from "./helpers/mock-server";
import { runHook } from "./helpers/run-hook";

const fixturesDir = path.resolve(__dirname, "fixtures");
const readEnvelope = (name: string) =>
  JSON.parse(fs.readFileSync(path.join(fixturesDir, "envelopes", name), "utf-8"));
const readExpected = (name: string) =>
  JSON.parse(fs.readFileSync(path.join(fixturesDir, "expected", name), "utf-8"));

describe("hook-script", () => {
  let server: ReturnType<typeof createMockServer>;
  let port: number;

  beforeAll(() => {
    try {
      execSync("which jq", { stdio: "ignore" });
    } catch {
      throw new Error("jq is required for hook script tests");
    }
  });

  beforeAll(async () => {
    server = createMockServer();
    port = await server.start();
  });

  afterAll(async () => {
    await server.stop();
  });

  beforeEach(() => {
    server.reset();
  });

  const hookEnv = () => ({
    TOQN_API_KEY: "test-key-123",
    TOQN_URL: `http://localhost:${port}`,
  });

  describe("Claude Code", () => {
    it("posts correct v2 payload for normal session", async () => {
      const envelope = readEnvelope("claude-code.json");
      const result = await runHook({
        source: "claude-code",
        envelope,
        transcriptFixture: "claude-code.jsonl",
        env: hookEnv(),
      });

      expect(result.exitCode).toBe(0);
      const req = server.getLastRequest();
      expect(req).not.toBeNull();

      const body = JSON.parse(req!.body);
      expect(body.session_id).toBe("");
      expect(body.project).toBe("my-app");
      expect(body.model).toBe("claude-sonnet-4-20250514");
      expect(body.turns).toHaveLength(2);
      expect(body.turns[0]).toEqual({ input: 1500, output: 300, cache_create: 200, cache_read: 100 });
      expect(body.turns[1]).toEqual({ input: 2000, output: 500, cache_create: 0, cache_read: 150 });
      expect(req!.headers["x-toqn-source"]).toBe("claude-code");
      expect(req!.headers["x-toqn-hook"]).toBe("6");
      expect(req!.headers.authorization).toBe("Bearer test-key-123");
    });

    it("sends only latest completion using stop_hook_summary boundaries", async () => {
      const envelope = readEnvelope("claude-code.json");
      const result = await runHook({
        source: "claude-code",
        envelope,
        transcriptFixture: "claude-code-multi-completion.jsonl",
        env: hookEnv(),
      });

      expect(result.exitCode).toBe(0);
      const req = server.getLastRequest();
      expect(req).not.toBeNull();

      const body = JSON.parse(req!.body);
      expect(body.turns).toHaveLength(3);
      expect(body.turns[0].input).toBe(3);
      expect(body.turns[0].output).toBe(50);
      expect(body.git_commits).toBe(1);
      expect(body.tools).toEqual({ Bash: 1, Edit: 1 });
      expect(body.lines_added).toBe(2);
      expect(body.lines_removed).toBe(1);
      expect(body.bash_categories).toEqual({ git_commit: 1 });
    });

    it("exits without POST when transcript is missing", async () => {
      const envelope = readEnvelope("claude-code-no-transcript.json");
      const result = await runHook({
        source: "claude-code",
        envelope,
        env: hookEnv(),
      });

      expect(result.exitCode).toBe(0);
      expect(server.getLastRequest()).toBeNull();
    });

    it("posts correct payload for single turn", async () => {
      const envelope = readEnvelope("claude-code.json");
      const result = await runHook({
        source: "claude-code",
        envelope,
        transcriptFixture: "claude-code-single.jsonl",
        env: hookEnv(),
      });

      expect(result.exitCode).toBe(0);
      const req = server.getLastRequest();
      expect(req).not.toBeNull();

      const body = JSON.parse(req!.body);
      expect(body.turns).toHaveLength(1);
      expect(body.turns[0].input).toBe(1000);
      expect(body.turns[0].output).toBe(200);
      expect(body.turns[0].cache_create).toBe(50);
      expect(body.turns[0].cache_read).toBe(0);
    });
  });

  describe("Cursor", () => {
    it("posts with estimated tokens from transcript", async () => {
      const envelope = readEnvelope("cursor-with-transcript.json");
      const result = await runHook({
        source: "cursor",
        envelope,
        transcriptFixture: "cursor.jsonl",
        env: hookEnv(),
      });

      expect(result.exitCode).toBe(0);
      const req = server.getLastRequest();
      expect(req).not.toBeNull();

      const body = JSON.parse(req!.body);
      const expected = readExpected("v2/cursor.json");
      expect(body).toEqual(expected);
      expect(req!.headers["x-toqn-source"]).toBe("cursor");
      expect(req!.headers["x-toqn-hook"]).toBe("6");
    });

    it("posts with zero estimates when no transcript", async () => {
      const envelope = readEnvelope("cursor.json");
      const result = await runHook({
        source: "cursor",
        envelope,
        env: hookEnv(),
      });

      expect(result.exitCode).toBe(0);
      const req = server.getLastRequest();
      expect(req).not.toBeNull();

      const body = JSON.parse(req!.body);
      expect(body.num_turns).toBe(0);
      expect(body.estimated_input_tokens).toBe(0);
      expect(body.estimated_output_tokens).toBe(0);
      expect(body.model).toBe("claude-sonnet-4-20250514");
    });
  });

  describe("Codex", () => {
    it("posts correct v2 payload from transcript", async () => {
      const envelope = readEnvelope("codex.json");
      const result = await runHook({
        source: "codex",
        envelope,
        transcriptFixture: "codex.jsonl",
        env: hookEnv(),
      });

      expect(result.exitCode).toBe(0);
      const req = server.getLastRequest();
      expect(req).not.toBeNull();

      const body = JSON.parse(req!.body);
      expect(body.session_id).toBe("019d5fdd-6a7f-7420-8f63-674b31244d10");
      expect(body.project).toBe("my-app");
      expect(body.model).toBe("gpt-5.4");
      expect(body.input_tokens).toBe(40550);
      expect(body.output_tokens).toBe(232);
      expect(body.cached_input_tokens).toBe(9600);
      expect(body.reasoning_output_tokens).toBe(58);
      expect(body.num_turns).toBe(1);
      // Tools include both exec_command (function_call) and apply_patch (custom_tool_call)
      expect(body.tools).toEqual({ exec_command: 3, apply_patch: 2 });
      expect(body.git_commits).toBe(1);
      expect(body.git_pushes).toBe(0);
      expect(body.bash_categories).toHaveProperty("git_commit", 1);
      // Lines from apply_patch: patch1 has +2 -1, patch2 has +3 -0
      expect(body.lines_added).toBe(5);
      expect(body.lines_removed).toBe(1);
      // Files changed from apply_patch headers
      expect(body.files_changed).toEqual({ ts: 2 });
      // Files read from cat/sed commands
      expect(body.files_read).toEqual({ md: 1, ts: 1 });
      expect(req!.headers["x-toqn-source"]).toBe("codex");
      expect(req!.headers["x-toqn-hook"]).toBe("6");
      expect(req!.headers.authorization).toBe("Bearer test-key-123");
    });

    it("sends only current turn delta using task_complete boundaries", async () => {
      const envelope = readEnvelope("codex.json");
      const result = await runHook({
        source: "codex",
        envelope,
        transcriptFixture: "codex-multi-turn.jsonl",
        env: hookEnv(),
      });

      expect(result.exitCode).toBe(0);
      const req = server.getLastRequest();
      expect(req).not.toBeNull();

      const body = JSON.parse(req!.body);
      expect(body.input_tokens).toBe(15000);
      expect(body.output_tokens).toBe(700);
      expect(body.cached_input_tokens).toBe(6000);
      expect(body.reasoning_output_tokens).toBe(200);
      expect(body.tools).toEqual({ exec_command: 1, read_file: 1 });
      expect(body.git_commits).toBe(1);
      expect(body.bash_categories).toHaveProperty("git_commit", 1);
      expect(body.num_turns).toBe(1);
    });

    it("exits without POST when transcript is missing", async () => {
      const envelope = readEnvelope("codex-no-transcript.json");
      const result = await runHook({
        source: "codex",
        envelope,
        env: hookEnv(),
      });

      expect(result.exitCode).toBe(0);
      expect(server.getLastRequest()).toBeNull();
    });
  });

  describe("Copilot", () => {
    it("posts with estimated tokens from JSON transcript", async () => {
      // Clean offset so test is isolated
      try { fs.unlinkSync("/tmp/toqn-copilot-offsets/copilot-sess-456"); } catch {}
      const envelope = readEnvelope("copilot-with-transcript.json");
      const result = await runHook({
        source: "copilot",
        envelope,
        transcriptFixture: "copilot.json",
        env: hookEnv(),
      });

      expect(result.exitCode).toBe(0);
      const req = server.getLastRequest();
      expect(req).not.toBeNull();

      const body = JSON.parse(req!.body);
      expect(body.model).toBe("gpt-4o");
      expect(body.project).toBe("my-app");
      expect(body.session_id).toBe("copilot-sess-456");
      expect(body.num_turns).toBe(3);
      expect(body.estimated_input_tokens).toBeGreaterThan(0);
      expect(body.estimated_output_tokens).toBeGreaterThan(0);
      expect(body.tools).toHaveProperty("createFile");
      expect(body.tools).toHaveProperty("editFiles");
      expect(body.tools).toHaveProperty("runTerminalCommand");
      expect(req!.headers["x-toqn-source"]).toBe("copilot");
      expect(req!.headers["x-toqn-hook"]).toBe("6");
    });

    it("posts with zero estimates when no transcript", async () => {
      const envelope = readEnvelope("copilot.json");
      const result = await runHook({
        source: "copilot",
        envelope,
        env: hookEnv(),
      });

      expect(result.exitCode).toBe(0);
      const req = server.getLastRequest();
      expect(req).not.toBeNull();

      const body = JSON.parse(req!.body);
      expect(body.num_turns).toBe(0);
      expect(body.estimated_input_tokens).toBe(0);
      expect(body.estimated_output_tokens).toBe(0);
      expect(body.model).toBe("unknown");
      expect(body.project).toBe("my-app");
      expect(body.session_id).toBe("copilot-sess-123");
    });

    it("only counts new messages on repeated Stop (no inflation)", async () => {
      const envelope = { ...readEnvelope("copilot-with-transcript.json"), sessionId: "copilot-dedup-test" };

      // Clean up any stale offset file from previous runs
      const offsetFile = "/tmp/toqn-copilot-offsets/copilot-dedup-test";
      try { fs.unlinkSync(offsetFile); } catch {}

      // First invocation: should report tokens
      const result1 = await runHook({
        source: "copilot",
        envelope,
        transcriptFixture: "copilot.json",
        env: hookEnv(),
      });
      expect(result1.exitCode).toBe(0);
      const body1 = JSON.parse(server.getLastRequest()!.body);
      expect(body1.num_turns).toBe(3);
      expect(body1.estimated_input_tokens).toBeGreaterThan(0);
      expect(body1.estimated_output_tokens).toBeGreaterThan(0);

      server.reset();

      // Second invocation with same transcript: should report zero new activity
      const result2 = await runHook({
        source: "copilot",
        envelope,
        transcriptFixture: "copilot.json",
        env: hookEnv(),
      });
      expect(result2.exitCode).toBe(0);
      const body2 = JSON.parse(server.getLastRequest()!.body);
      expect(body2.num_turns).toBe(0);
      expect(body2.estimated_input_tokens).toBe(0);
      expect(body2.estimated_output_tokens).toBe(0);
      expect(body2.model).toBe("gpt-4o");

      // Clean up
      try { fs.unlinkSync(offsetFile); } catch {}
    });
  });

  describe("edge cases", () => {
    it("exits without POST when no API key", async () => {
      const envelope = readEnvelope("claude-code.json");
      const result = await runHook({
        source: "claude-code",
        envelope,
        transcriptFixture: "claude-code.jsonl",
      });

      expect(result.exitCode).toBe(0);
      expect(server.getLastRequest()).toBeNull();
    });

    it("outputs debug log path in stderr when debug mode enabled", async () => {
      const envelope = readEnvelope("claude-code.json");
      const result = await runHook({
        source: "claude-code",
        envelope,
        transcriptFixture: "claude-code.jsonl",
        env: {
          ...hookEnv(),
          TOQN_DEBUG: "1",
        },
      });

      expect(result.exitCode).toBe(0);
      expect(result.stderr).toContain("toqn: debug log at");
      expect(result.stderr).toContain("/tmp/toqn-debug/");
    });

    it("exits with error when no source arg provided", async () => {
      const envelope = readEnvelope("claude-code.json");
      const result = await runHook({
        source: "",
        envelope,
        transcriptFixture: "claude-code.jsonl",
        env: hookEnv(),
      });

      expect(result.exitCode).toBe(1);
      expect(result.stderr).toContain("usage:");
    });
  });
});
