import { execFile, type ExecFileException } from "child_process";
import fs from "fs";
import os from "os";
import path from "path";

interface RunInstallerOptions {
  /** Files to pre-populate in the sandboxed HOME, relative paths → content */
  homeFiles?: Record<string, string>;
  /** Directories to pre-create in HOME */
  homeDirs?: string[];
  /** The port of the mock server serving the hook script */
  mockServerPort: number;
  /** The installer script content (from hook-script route) */
  installerScript: string;
  /** API key argument */
  apiKey?: string;
  /** Skip passing the API key argument entirely */
  skipApiKey?: boolean;
  /** Input to feed via simulated /dev/tty (for interactive prompt testing) */
  ttyInput?: string;
  /** Reuse an existing HOME dir instead of creating a new one */
  existingHomeDir?: string;
  /** Transform to apply to the installer script before running */
  scriptTransform?: (script: string) => string;
}

interface RunInstallerResult {
  exitCode: number;
  stdout: string;
  stderr: string;
  homeDir: string;
  readFile: (relativePath: string) => string | null;
  fileExists: (relativePath: string) => boolean;
  cleanup: () => void;
}

export function runInstaller(options: RunInstallerOptions): Promise<RunInstallerResult> {
  const {
    homeFiles = {},
    homeDirs = [],
    mockServerPort,
    installerScript,
    apiKey = "test-api-key-123",
    skipApiKey = false,
    ttyInput,
    existingHomeDir,
    scriptTransform,
  } = options;

  const homeDir = existingHomeDir || fs.mkdtempSync(path.join(os.tmpdir(), "tp-installer-test-"));

  // Create directories
  for (const dir of homeDirs) {
    fs.mkdirSync(path.join(homeDir, dir), { recursive: true });
  }

  // Create files
  for (const [relPath, content] of Object.entries(homeFiles)) {
    const fullPath = path.join(homeDir, relPath);
    fs.mkdirSync(path.dirname(fullPath), { recursive: true });
    fs.writeFileSync(fullPath, content);
  }

  // Replace the download URL in the installer script to point at mock server
  let modifiedScript = installerScript.replace(
    /curl -fsSL "https:\/\/toqn\.dev\/scripts\/toqn-hook\.sh"/,
    `curl -fsSL "http://localhost:${mockServerPort}/scripts/toqn-hook.sh"`
  );

  // Replace /dev/tty prompts with defaults (no tty in test environment)
  modifiedScript = modifiedScript.replace(
    /printf "Auto-update hook script\? \[Y\/n\] " > \/dev\/tty\nread -r ANSWER < \/dev\/tty 2>\/dev\/null \|\| ANSWER="y"/,
    'ANSWER="y"'
  );

  if (scriptTransform) {
    modifiedScript = scriptTransform(modifiedScript);
  }

  // When ttyInput is provided, create a file to simulate /dev/tty input
  // and patch the script to read from that file instead of /dev/tty
  let ttyFile: string | undefined;
  if (ttyInput !== undefined) {
    ttyFile = path.join(homeDir, "_tty_input");
    fs.writeFileSync(ttyFile, ttyInput);
    modifiedScript = modifiedScript.replace(
      /read -r API_KEY < \/dev\/tty/,
      `read -r API_KEY < "${ttyFile}"`
    );
    // Make the TTY check pass by replacing /dev/tty-based checks
    // with a check for our fake tty file
    modifiedScript = modifiedScript.replace(
      /if \[ -t 0 \] \|\| \[ -t 2 \]/,
      `if [ -f "${ttyFile}" ]`
    );
  }

  const scriptPath = path.join(homeDir, "_installer.sh");
  fs.writeFileSync(scriptPath, modifiedScript, { mode: 0o755 });

  const args = skipApiKey ? [scriptPath] : [scriptPath, apiKey];

  return new Promise((resolve) => {
    execFile(
      "bash",
      args,
      {
        env: {
          PATH: process.env.PATH,
          HOME: homeDir,
        } as unknown as NodeJS.ProcessEnv,
        timeout: 10000,
      },
      (error: ExecFileException | null, stdout: string, stderr: string) => {
        resolve({
          exitCode: error?.code ? (typeof error.code === "number" ? error.code : 1) : 0,
          stdout: stdout.toString(),
          stderr: stderr.toString(),
          homeDir,
          readFile: (relativePath: string) => {
            const p = path.join(homeDir, relativePath);
            try {
              return fs.readFileSync(p, "utf-8");
            } catch {
              return null;
            }
          },
          fileExists: (relativePath: string) => fs.existsSync(path.join(homeDir, relativePath)),
          cleanup: () => fs.rmSync(homeDir, { recursive: true, force: true }),
        });
      }
    );
  });
}
