export const DEFAULT_AUDIENCE = "api://709bbe94-f759-422f-b7fa-28f1fde28ae1";
const TOKEN_REFRESH_SKEW_MS = 5 * 60 * 1000;
const ALLOWED_URL = /^https:\/\/api\.(dev|int)\.amnhealthcare\.io\/ai\/new-relic-mcp\/\1$/;

export function parseArguments(argv) {
    const options = {
        audience: DEFAULT_AUDIENCE,
        azPath: process.platform === "win32" ? "az.cmd" : "az",
        url: undefined,
    };

    for (let index = 0; index < argv.length; index += 1) {
        const argument = argv[index];
        if (argument === "--url" || argument === "--audience" || argument === "--az-path") {
            const value = argv[index + 1];
            if (!value || value.startsWith("--")) {
                throw new Error(`${argument} requires a value.`);
            }
            const key = argument === "--az-path" ? "azPath" : argument.slice(2);
            options[key] = value;
            index += 1;
        } else if (argument === "--help" || argument === "-h") {
            options.help = true;
        } else {
            throw new Error(`Unknown argument: ${argument}`);
        }
    }

    if (!options.help && !options.url) {
        throw new Error("--url is required.");
    }
    if (!options.help && !ALLOWED_URL.test(options.url)) {
        throw new Error("--url must be an AMN dev or int New Relic MCP APIM endpoint.");
    }
    if (!options.help && options.audience !== DEFAULT_AUDIENCE) {
        throw new Error("--audience must identify the AMN New Relic MCP Entra application.");
    }

    return options;
}

function tokenExpiry(token) {
    try {
        const payload = JSON.parse(Buffer.from(token.split(".")[1], "base64url").toString("utf8"));
        return Number.isFinite(payload.exp) ? payload.exp * 1000 : undefined;
    } catch {
        return undefined;
    }
}

export function createAzureTokenProvider({
    audience,
    now = () => Date.now(),
    runAz,
}) {
    if (typeof runAz !== "function") {
        throw new Error("An Azure CLI runner is required.");
    }
    let cachedToken;

    return {
        clear() {
            cachedToken = undefined;
        },
        async get({ forceRefresh = false } = {}) {
            if (
                !forceRefresh &&
                cachedToken &&
                cachedToken.expiresAt - TOKEN_REFRESH_SKEW_MS > now()
            ) {
                return cachedToken.value;
            }

            let result;
            try {
                result = await runAz([
                    "account",
                    "get-access-token",
                    "--resource",
                    audience,
                    "--query",
                    "accessToken",
                    "--output",
                    "tsv",
                    "--only-show-errors",
                ]);
            } catch (error) {
                const detail = error?.stderr?.trim();
                throw new Error(
                    detail
                        ? `Azure CLI token acquisition failed: ${detail}`
                        : "Azure CLI token acquisition failed. Run 'az login' and verify access.",
                );
            }

            const value = result.stdout.trim();
            if (!value) {
                throw new Error("Azure CLI returned an empty access token.");
            }

            cachedToken = {
                value,
                expiresAt: tokenExpiry(value) ?? now() + 10 * 60 * 1000,
            };
            return value;
        },
    };
}

export function createAuthenticatedFetch({
    tokenProvider,
    fetchImplementation = globalThis.fetch,
}) {
    return async (input, init = {}) => {
        const send = async (forceRefresh) => {
            const token = await tokenProvider.get({ forceRefresh });
            const headers = new Headers(input instanceof Request ? input.headers : undefined);
            new Headers(init.headers).forEach((value, name) => headers.set(name, value));
            headers.set("Authorization", `Bearer ${token}`);
            return fetchImplementation(input, { ...init, headers, redirect: "error" });
        };

        let response = await send(false);
        if (response.status !== 401 && response.status !== 403) {
            return response;
        }

        await response.body?.cancel();
        tokenProvider.clear();
        response = await send(true);
        return response;
    };
}
