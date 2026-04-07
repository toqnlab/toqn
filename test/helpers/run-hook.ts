import { execFile, type ExecFileException } from "child_process";
import fs from "fs";
import os from "os";
import path from "path";

interface RunHookOptions {
  source: string;
  envelope: Record<string, unknown>;
  transcriptFixture?: string;
  env?: Record<string, string>;
}

interface RunHookResult {
  exitCode: number;
  stdout: string;
  stderr: string;
}

export function runHook(options: RunHookOptions): Promise<RunHookResult> {
  const { envelope, transcriptFixture, env = {} } = options;
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "tp-hook-test-"));
  const modifiedEnvelope = { ...envelope };

  if (transcriptFixture) {
    const src = path.resolve(__dirname, "../fixtures/transcripts", transcriptFixture);
    const ext = path.extname(transcriptFixture) || ".jsonl";
    const dest = path.join(tmpDir, `transcript${ext}`);
    fs.copyFileSync(src, dest);

    if (modifiedEnvelope.transcript_path === "PLACEHOLDER") {
      modifiedEnvelope.transcript_path = dest;
    }
  } else {
    // Remove PLACEHOLDER so it doesn't point to a nonexistent file
    if (modifiedEnvelope.transcript_path === "PLACEHOLDER") {
      delete modifiedEnvelope.transcript_path;
    }
  }

  const stdinData = JSON.stringify(modifiedEnvelope);
  const scriptPath = path.resolve(__dirname, "../../scripts/toqn-hook.sh");

  return new Promise((resolve) => {
    const child = execFile(
      "bash",
      [scriptPath, ...(options.source ? [options.source] : [])],
      {
        env: {
          PATH: process.env.PATH,
          HOME: env.HOME || os.tmpdir(),
          ...env,
        } as unknown as NodeJS.ProcessEnv,
        timeout: 10000,
      },
      (error: ExecFileException | null, stdout: string, stderr: string) => {
        // Clean up temp dir
        fs.rmSync(tmpDir, { recursive: true, force: true });
        resolve({
          exitCode: error?.code ? (typeof error.code === "number" ? error.code : 1) : 0,
          stdout: stdout.toString(),
          stderr: stderr.toString(),
        });
      }
    );

    child.stdin?.write(stdinData);
    child.stdin?.end();
  });
}
