import { describe, it, expect, beforeAll, afterAll, beforeEach } from "vitest";
import fs from "fs";
import path from "path";
import { createMockServer } from "./helpers/mock-server";
import { runInstaller } from "./helpers/run-installer";

function getInstallerScript(): string {
  return fs.readFileSync(
    path.resolve(__dirname, "../scripts/install.sh"),
    "utf-8"
  );
}

describe("installer", () => {
  let server: ReturnType<typeof createMockServer>;
  let port: number;
  let installerScript: string;

  beforeAll(async () => {
    installerScript = getInstallerScript();
    server = createMockServer();
    port = await server.start();
  });

  afterAll(async () => {
    await server.stop();
  });

  beforeEach(() => {
    server.reset();
  });

  it("creates settings.json for Claude Code only", async () => {
    const result = await runInstaller({
      homeDirs: [".claude"],
      mockServerPort: port,
      installerScript,
    });

    try {
      expect(result.exitCode).toBe(0);
      expect(result.fileExists(".toqn/hook.sh")).toBe(true);
      expect(result.fileExists(".claude/settings.json")).toBe(true);

      const settings = JSON.parse(result.readFile(".claude/settings.json")!);
      expect(settings.hooks.Stop).toBeDefined();
      expect(settings.hooks.Stop[0].hooks[0].command).toContain("hook.sh");
    } finally {
      result.cleanup();
    }
  });

  it("creates hooks.json for Cursor only", async () => {
    const result = await runInstaller({
      homeDirs: [".cursor"],
      mockServerPort: port,
      installerScript,
    });

    try {
      expect(result.exitCode).toBe(0);
      expect(result.fileExists(".cursor/hooks.json")).toBe(true);

      const hooks = JSON.parse(result.readFile(".cursor/hooks.json")!);
      expect(hooks.hooks.stop).toBeDefined();
      expect(hooks.hooks.stop[0].command).toContain("hook.sh cursor");
    } finally {
      result.cleanup();
    }
  });

  it("configures both tools when both dirs exist", async () => {
    const result = await runInstaller({
      homeDirs: [".claude", ".cursor"],
      mockServerPort: port,
      installerScript,
    });

    try {
      expect(result.exitCode).toBe(0);
      expect(result.fileExists(".claude/settings.json")).toBe(true);
      expect(result.fileExists(".cursor/hooks.json")).toBe(true);
    } finally {
      result.cleanup();
    }
  });

  it("creates hooks.json for Codex only", async () => {
    const result = await runInstaller({
      homeDirs: [".codex"],
      homeFiles: {
        ".codex/config.toml": 'model = "gpt-5.4"\n',
      },
      mockServerPort: port,
      installerScript,
    });

    try {
      expect(result.exitCode).toBe(0);
      expect(result.fileExists(".codex/hooks.json")).toBe(true);

      const hooks = JSON.parse(result.readFile(".codex/hooks.json")!);
      expect(hooks.hooks.Stop).toBeDefined();
      expect(hooks.hooks.Stop[0].hooks[0].command).toContain("hook.sh codex");

      // Feature flag should be enabled
      const config = result.readFile(".codex/config.toml")!;
      expect(config).toContain("codex_hooks=true");
    } finally {
      result.cleanup();
    }
  });

  it("enables codex_hooks feature flag in existing config.toml", async () => {
    const result = await runInstaller({
      homeDirs: [".codex"],
      homeFiles: {
        ".codex/config.toml": 'model = "gpt-5.4"\n\n[features]\nrmcp_client=true\n',
      },
      mockServerPort: port,
      installerScript,
    });

    try {
      expect(result.exitCode).toBe(0);
      const config = result.readFile(".codex/config.toml")!;
      expect(config).toContain("codex_hooks=true");
      expect(config).toContain("rmcp_client=true");
    } finally {
      result.cleanup();
    }
  });

  it("configures all three tools when all dirs exist", async () => {
    const result = await runInstaller({
      homeDirs: [".claude", ".codex", ".cursor"],
      homeFiles: {
        ".codex/config.toml": 'model = "gpt-5.4"\n',
      },
      mockServerPort: port,
      installerScript,
    });

    try {
      expect(result.exitCode).toBe(0);
      expect(result.fileExists(".claude/settings.json")).toBe(true);
      expect(result.fileExists(".codex/hooks.json")).toBe(true);
      expect(result.fileExists(".cursor/hooks.json")).toBe(true);
    } finally {
      result.cleanup();
    }
  });

  it("preserves existing hooks in settings.json", async () => {
    const existingSettings = {
      hooks: {
        Stop: [
          {
            matcher: "",
            hooks: [{ type: "command", command: "echo existing" }],
          },
        ],
      },
    };

    const result = await runInstaller({
      homeDirs: [".claude"],
      homeFiles: {
        ".claude/settings.json": JSON.stringify(existingSettings, null, 2),
      },
      mockServerPort: port,
      installerScript,
    });

    try {
      expect(result.exitCode).toBe(0);
      const settings = JSON.parse(result.readFile(".claude/settings.json")!);
      // Should have both the existing hook and the new one
      expect(settings.hooks.Stop.length).toBeGreaterThanOrEqual(2);
      const commands = settings.hooks.Stop.map(
        (s: { hooks: { command: string }[] }) => s.hooks[0].command
      );
      expect(commands).toContain("echo existing");
      expect(commands.some((c: string) => c.includes("hook.sh"))).toBe(true);
    } finally {
      result.cleanup();
    }
  });

  it("updates API key in shell config on re-run", async () => {
    const result = await runInstaller({
      homeFiles: {
        ".zshrc": 'export TOQN_API_KEY="old-key"\n',
      },
      homeDirs: [".claude"],
      mockServerPort: port,
      installerScript,
      apiKey: "new-key-456",
    });

    try {
      expect(result.exitCode).toBe(0);
      const zshrc = result.readFile(".zshrc")!;
      const matches = zshrc.match(/TOQN_API_KEY/g);
      expect(matches?.length).toBe(1);
      expect(zshrc).toContain('TOQN_API_KEY="new-key-456"');
      expect(zshrc).not.toContain("old-key");
      expect(result.stdout).toContain("Save API key to");
    } finally {
      result.cleanup();
    }
  });

  it("removes old hook file if present", async () => {
    const result = await runInstaller({
      homeDirs: [".claude"],
      homeFiles: {
        ".claude/hooks/toqn-hook.sh": "#!/bin/bash\necho old",
      },
      mockServerPort: port,
      installerScript,
    });

    try {
      expect(result.exitCode).toBe(0);
      expect(result.fileExists(".claude/hooks/toqn-hook.sh")).toBe(false);
      expect(result.fileExists(".claude/hooks/toqn-hook.sh")).toBe(false);
    } finally {
      result.cleanup();
    }
  });

  it("installs hook script even when neither tool dir exists", async () => {
    const result = await runInstaller({
      homeFiles: { ".zshrc": "" },
      mockServerPort: port,
      installerScript,
    });

    try {
      expect(result.exitCode).toBe(0);
      expect(result.fileExists(".toqn/hook.sh")).toBe(true);
      expect(result.stdout).toContain("No supported tool found");
    } finally {
      result.cleanup();
    }
  });

  it("skips settings.json rewrite when hook already configured", async () => {
    // First run to get hook installed with correct paths
    const result1 = await runInstaller({
      homeDirs: [".claude"],
      mockServerPort: port,
      installerScript,
    });

    expect(result1.exitCode).toBe(0);
    // Inject a custom key and use 4-space indent to detect any reformatting
    const settings = JSON.parse(result1.readFile(".claude/settings.json")!);
    settings.customKey = "user-value";
    const customContent = JSON.stringify(settings, null, 4);
    fs.writeFileSync(
      path.join(result1.homeDir, ".claude/settings.json"),
      customContent
    );

    // Second run should skip
    const result2 = await runInstaller({
      existingHomeDir: result1.homeDir,
      mockServerPort: port,
      installerScript,
    });

    try {
      expect(result2.exitCode).toBe(0);
      expect(result2.stdout).toContain("Configure Claude Code");
      // File should be byte-for-byte identical (no reformat)
      const afterContent = result2.readFile(".claude/settings.json")!;
      expect(afterContent).toBe(customContent);
    } finally {
      result1.cleanup();
    }
  });

  it("skips Cursor hooks.json rewrite when hook already configured", async () => {
    // First run to get hook installed with correct paths
    const result1 = await runInstaller({
      homeDirs: [".cursor"],
      mockServerPort: port,
      installerScript,
    });

    expect(result1.exitCode).toBe(0);
    const hooks = JSON.parse(result1.readFile(".cursor/hooks.json")!);
    hooks.customKey = "user-value";
    const customContent = JSON.stringify(hooks, null, 4);
    fs.writeFileSync(
      path.join(result1.homeDir, ".cursor/hooks.json"),
      customContent
    );

    // Second run should skip
    const result2 = await runInstaller({
      existingHomeDir: result1.homeDir,
      mockServerPort: port,
      installerScript,
    });

    try {
      expect(result2.exitCode).toBe(0);
      expect(result2.stdout).toContain("Configure Cursor");
      const afterContent = result2.readFile(".cursor/hooks.json")!;
      expect(afterContent).toBe(customContent);
    } finally {
      result1.cleanup();
    }
  });

  it("uses python3 fallback for Claude Code when jq is unavailable", async () => {
    const noJq = (s: string) => s.replace(/command -v jq/g, "false");
    const existingSettings = {
      customKey: "preserve-me",
      hooks: {
        Stop: [
          {
            matcher: "",
            hooks: [{ type: "command", command: "echo existing" }],
          },
        ],
      },
    };

    const result = await runInstaller({
      homeDirs: [".claude"],
      homeFiles: {
        ".claude/settings.json": JSON.stringify(existingSettings, null, 2),
      },
      mockServerPort: port,
      installerScript,
      scriptTransform: noJq,
    });

    try {
      expect(result.exitCode).toBe(0);
      const settings = JSON.parse(result.readFile(".claude/settings.json")!);
      // Existing data preserved
      expect(settings.customKey).toBe("preserve-me");
      // Both hooks present
      expect(settings.hooks.Stop.length).toBeGreaterThanOrEqual(2);
      const commands = settings.hooks.Stop.map(
        (s: { hooks: { command: string }[] }) => s.hooks[0].command
      );
      expect(commands).toContain("echo existing");
      expect(commands.some((c: string) => c.includes("hook.sh"))).toBe(true);
    } finally {
      result.cleanup();
    }
  });

  it("uses python3 fallback for Cursor when jq is unavailable", async () => {
    const noJq = (s: string) => s.replace(/command -v jq/g, "false");
    const existingHooks = {
      version: 1,
      customKey: "preserve-me",
      hooks: {
        stop: [
          {
            command: "/usr/local/bin/other-hook.sh",
          },
        ],
      },
    };

    const result = await runInstaller({
      homeDirs: [".cursor"],
      homeFiles: {
        ".cursor/hooks.json": JSON.stringify(existingHooks, null, 2),
      },
      mockServerPort: port,
      installerScript,
      scriptTransform: noJq,
    });

    try {
      expect(result.exitCode).toBe(0);
      const hooks = JSON.parse(result.readFile(".cursor/hooks.json")!);
      // Existing data preserved
      expect(hooks.customKey).toBe("preserve-me");
      expect(hooks.version).toBe(1);
      // Both hooks present
      expect(hooks.hooks.stop.length).toBe(2);
      const commands = hooks.hooks.stop.map(
        (h: { command: string }) => h.command
      );
      expect(commands).toContain("/usr/local/bin/other-hook.sh");
      expect(commands.some((c: string) => c.includes("hook.sh cursor"))).toBe(true);
    } finally {
      result.cleanup();
    }
  });

  it("preserves existing Cursor hooks.json when merging", async () => {
    const existingHooks = {
      version: 1,
      hooks: {
        stop: [
          {
            command: "/usr/local/bin/other-hook.sh",
          },
        ],
      },
    };

    const result = await runInstaller({
      homeDirs: [".cursor"],
      homeFiles: {
        ".cursor/hooks.json": JSON.stringify(existingHooks, null, 2),
      },
      mockServerPort: port,
      installerScript,
    });

    try {
      expect(result.exitCode).toBe(0);
      const hooks = JSON.parse(result.readFile(".cursor/hooks.json")!);
      expect(hooks.hooks.stop.length).toBe(2);
      const commands = hooks.hooks.stop.map(
        (h: { command: string }) => h.command
      );
      expect(commands).toContain("/usr/local/bin/other-hook.sh");
      expect(commands.some((c: string) => c.includes("hook.sh cursor"))).toBe(true);
    } finally {
      result.cleanup();
    }
  });

  it("fails with error when no API key and no TTY", async () => {
    const noDeviceAuth = (s: string) =>
      s.replace(
        /DEVICE_RESP=\$\(curl -sf --connect-timeout 3 -X POST[^)]*\)/,
        'DEVICE_RESP=""'
      );
    const result = await runInstaller({
      homeDirs: [".claude"],
      mockServerPort: port,
      installerScript,
      skipApiKey: true,
      scriptTransform: noDeviceAuth,
    });

    try {
      expect(result.exitCode).toBe(1);
      expect(result.stderr).toContain("API key is required");
      expect(result.stderr).toContain("Usage:");
      expect(result.fileExists(".toqn/hook.sh")).toBe(false);
    } finally {
      result.cleanup();
    }
  });

  it("prompts for API key interactively via TTY", async () => {
    const noDeviceAuth = (s: string) =>
      s.replace(
        /DEVICE_RESP=\$\(curl -sf --connect-timeout 3 -X POST[^)]*\)/,
        'DEVICE_RESP=""'
      );
    const result = await runInstaller({
      homeDirs: [".claude"],
      homeFiles: { ".zshrc": "" },
      mockServerPort: port,
      installerScript,
      skipApiKey: true,
      ttyInput: "tty-key-789\n",
      scriptTransform: noDeviceAuth,
    });

    try {
      expect(result.exitCode).toBe(0);
      expect(result.fileExists(".toqn/hook.sh")).toBe(true);

      // API key from TTY should be saved in shell config
      const zshrc = result.readFile(".zshrc");
      expect(zshrc).toContain('TOQN_API_KEY="tty-key-789"');

      // Welcome message should appear
      expect(result.stdout).toContain("toqn");
      expect(result.stdout).toContain("toqn.dev/settings");
    } finally {
      result.cleanup();
    }
  });

  it("prefers CLI argument over TTY when both available", async () => {
    const result = await runInstaller({
      homeDirs: [".claude"],
      homeFiles: { ".zshrc": "" },
      mockServerPort: port,
      installerScript,
      apiKey: "cli-key-abc",
      ttyInput: "tty-key-xyz\n",
    });

    try {
      expect(result.exitCode).toBe(0);
      const zshrc = result.readFile(".zshrc");
      expect(zshrc).toContain('TOQN_API_KEY="cli-key-abc"');
      expect(zshrc).not.toContain("tty-key-xyz");
    } finally {
      result.cleanup();
    }
  });

  it("is idempotent on re-run", async () => {
    // First run
    const result1 = await runInstaller({
      homeDirs: [".claude"],
      mockServerPort: port,
      installerScript,
    });

    expect(result1.exitCode).toBe(0);

    // Second run in the SAME home dir
    const result2 = await runInstaller({
      existingHomeDir: result1.homeDir,
      mockServerPort: port,
      installerScript,
    });

    try {
      expect(result2.exitCode).toBe(0);
      const settings = JSON.parse(result2.readFile(".claude/settings.json")!);
      // unique_by should prevent duplicates
      const hookCommands = settings.hooks.Stop.map(
        (s: { hooks: { command: string }[] }) => s.hooks[0].command
      );
      const tpHooks = hookCommands.filter((c: string) => c.includes("hook.sh"));
      expect(tpHooks.length).toBe(1);
    } finally {
      result1.cleanup();
    }
  });

  // --- Migration tests ---

  it("migrates old .tokenprofile directory", async () => {
    const result = await runInstaller({
      homeDirs: [".claude", ".tokenprofile"],
      homeFiles: {
        ".tokenprofile/hook.sh": "#!/bin/bash\necho old hook",
      },
      mockServerPort: port,
      installerScript,
    });

    try {
      expect(result.exitCode).toBe(0);
      expect(result.fileExists(".tokenprofile")).toBe(false);
      expect(result.fileExists(".toqn/hook.sh")).toBe(true);
    } finally {
      result.cleanup();
    }
  });

  it("migrates old TOKEN_PROFILE_API_KEY env var", async () => {
    const result = await runInstaller({
      homeFiles: {
        ".zshrc": 'export TOKEN_PROFILE_API_KEY="old-key"\nexport OTHER_VAR="keep"\n',
      },
      homeDirs: [".claude"],
      mockServerPort: port,
      installerScript,
      apiKey: "new-key-789",
    });

    try {
      expect(result.exitCode).toBe(0);
      const zshrc = result.readFile(".zshrc")!;
      expect(zshrc).not.toContain("TOKEN_PROFILE_API_KEY");
      expect(zshrc).toContain("OTHER_VAR");
      expect(zshrc).toContain('TOQN_API_KEY="new-key-789"');
      expect(result.exitCode).toBe(0);
    } finally {
      result.cleanup();
    }
  });

  it("cleans old tokenprofile hook from Claude Code settings", async () => {
    const oldSettings = {
      hooks: {
        Stop: [
          {
            matcher: "",
            hooks: [
              {
                type: "command",
                command: "bash ~/.tokenprofile/hook.sh",
                async: true,
              },
            ],
          },
          {
            matcher: "",
            hooks: [{ type: "command", command: "echo keep-me" }],
          },
        ],
      },
    };

    const result = await runInstaller({
      homeDirs: [".claude"],
      homeFiles: {
        ".claude/settings.json": JSON.stringify(oldSettings, null, 2),
      },
      mockServerPort: port,
      installerScript,
    });

    try {
      expect(result.exitCode).toBe(0);
      const settings = JSON.parse(result.readFile(".claude/settings.json")!);
      // Old tokenprofile hook should be gone
      const commands = settings.hooks.Stop.map(
        (s: { hooks: { command: string }[] }) => s.hooks[0].command
      );
      expect(commands).not.toContain("bash ~/.tokenprofile/hook.sh");
      // The other hook and new toqn hook should remain
      expect(commands).toContain("echo keep-me");
      expect(commands.some((c: string) => c.includes(".toqn/hook.sh"))).toBe(true);
      expect(result.exitCode).toBe(0);
    } finally {
      result.cleanup();
    }
  });

  it("cleans old tokenprofile hook from Cursor hooks", async () => {
    const oldHooks = {
      version: 1,
      hooks: {
        stop: [
          {
            command: "/bin/bash",
            args: ["~/.tokenprofile/hook.sh"],
          },
          {
            command: "/usr/local/bin/other-hook.sh",
          },
        ],
      },
    };

    const result = await runInstaller({
      homeDirs: [".cursor"],
      homeFiles: {
        ".cursor/hooks.json": JSON.stringify(oldHooks, null, 2),
      },
      mockServerPort: port,
      installerScript,
    });

    try {
      expect(result.exitCode).toBe(0);
      const hooks = JSON.parse(result.readFile(".cursor/hooks.json")!);
      const commands = hooks.hooks.stop.map((h: { command: string }) => h.command);
      expect(commands.some((c: string) => c.includes(".tokenprofile"))).toBe(false);
      expect(commands).toContain("/usr/local/bin/other-hook.sh");
      expect(commands.some((c: string) => c.includes(".toqn/hook.sh cursor"))).toBe(true);
      expect(result.exitCode).toBe(0);
    } finally {
      result.cleanup();
    }
  });

  it("migration is idempotent", async () => {
    // First run with old artifacts
    const result1 = await runInstaller({
      homeDirs: [".claude", ".tokenprofile"],
      homeFiles: {
        ".tokenprofile/hook.sh": "#!/bin/bash\necho old",
        ".zshrc": 'export TOKEN_PROFILE_API_KEY="old-key"\n',
      },
      mockServerPort: port,
      installerScript,
    });

    expect(result1.exitCode).toBe(0);
    expect(result1.fileExists(".tokenprofile")).toBe(false);

    // Second run in the same home dir (no old artifacts remain)
    const result2 = await runInstaller({
      existingHomeDir: result1.homeDir,
      mockServerPort: port,
      installerScript,
    });

    try {
      expect(result2.exitCode).toBe(0);
      expect(result2.fileExists(".toqn/hook.sh")).toBe(true);
    } finally {
      result1.cleanup();
    }
  });
});
