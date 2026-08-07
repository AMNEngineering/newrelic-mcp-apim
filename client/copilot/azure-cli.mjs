import spawn from "cross-spawn";

const MAX_OUTPUT_BYTES = 1024 * 1024;
const AZURE_CLI_TIMEOUT_MS = 30 * 1000;

export function runAzureCli(azPath, args) {
    return new Promise((resolve, reject) => {
        const child = spawn(azPath, args, {
            stdio: ["ignore", "pipe", "pipe"],
            windowsHide: true,
        });
        const stdout = [];
        const stderr = [];
        let stdoutBytes = 0;
        let stderrBytes = 0;
        let settled = false;
        const terminate = () => child.kill();
        const timeout = setTimeout(terminate, AZURE_CLI_TIMEOUT_MS);
        timeout.unref?.();

        process.once("SIGINT", terminate);
        process.once("SIGTERM", terminate);
        process.stdin.once("end", terminate);
        process.stdin.once("close", terminate);

        const cleanup = () => {
            clearTimeout(timeout);
            process.removeListener("SIGINT", terminate);
            process.removeListener("SIGTERM", terminate);
            process.stdin.removeListener("end", terminate);
            process.stdin.removeListener("close", terminate);
        };

        child.stdout.on("data", (chunk) => {
            stdoutBytes += chunk.length;
            if (stdoutBytes <= MAX_OUTPUT_BYTES) {
                stdout.push(chunk);
            } else {
                child.kill();
            }
        });
        child.stderr.on("data", (chunk) => {
            stderrBytes += chunk.length;
            if (stderrBytes <= MAX_OUTPUT_BYTES) {
                stderr.push(chunk);
            } else {
                child.kill();
            }
        });
        child.once("error", (error) => {
            if (!settled) {
                settled = true;
                cleanup();
                reject(error);
            }
        });
        child.once("close", (code, signal) => {
            if (settled) {
                return;
            }
            settled = true;
            cleanup();
            const result = {
                stdout: Buffer.concat(stdout).toString("utf8"),
                stderr: Buffer.concat(stderr).toString("utf8"),
            };
            if (stdoutBytes > MAX_OUTPUT_BYTES || stderrBytes > MAX_OUTPUT_BYTES) {
                reject(Object.assign(new Error("Azure CLI output exceeded the safety limit."), result));
            } else if (signal) {
                reject(
                    Object.assign(
                        new Error(
                            signal === "SIGTERM"
                                ? "Azure CLI token acquisition timed out or was cancelled."
                                : `Azure CLI was terminated by ${signal}.`,
                        ),
                        result,
                    ),
                );
            } else if (code !== 0) {
                reject(
                    Object.assign(
                        new Error(`Azure CLI exited with code ${code ?? "unknown"}${signal ? ` (${signal})` : ""}.`),
                        result,
                    ),
                );
            } else {
                resolve(result);
            }
        });
    });
}
