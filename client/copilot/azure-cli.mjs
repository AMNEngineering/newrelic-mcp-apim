import spawn from "cross-spawn";

const MAX_OUTPUT_BYTES = 1024 * 1024;

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
        child.once("error", reject);
        child.once("close", (code, signal) => {
            const result = {
                stdout: Buffer.concat(stdout).toString("utf8"),
                stderr: Buffer.concat(stderr).toString("utf8"),
            };
            if (stdoutBytes > MAX_OUTPUT_BYTES || stderrBytes > MAX_OUTPUT_BYTES) {
                reject(Object.assign(new Error("Azure CLI output exceeded the safety limit."), result));
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
