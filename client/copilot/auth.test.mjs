import assert from "node:assert/strict";
import test from "node:test";

import {
    DEFAULT_AUDIENCE,
    createAuthenticatedFetch,
    createAzureTokenProvider,
    parseArguments,
} from "./auth.mjs";

function jwtWithExpiry(expirySeconds) {
    const payload = Buffer.from(JSON.stringify({ exp: expirySeconds })).toString("base64url");
    return `header.${payload}.signature`;
}

test("parseArguments accepts only the fixed AMN endpoint and audience", () => {
    const options = parseArguments([
        "--url",
        "https://api.int.amnhealthcare.io/ai/new-relic-mcp/int",
        "--audience",
        DEFAULT_AUDIENCE,
        "--az-path",
        "/opt/homebrew/bin/az",
    ]);

    assert.equal(options.url, "https://api.int.amnhealthcare.io/ai/new-relic-mcp/int");
    assert.equal(options.audience, DEFAULT_AUDIENCE);
    assert.equal(options.azPath, "/opt/homebrew/bin/az");

    assert.throws(
        () => parseArguments(["--url", "https://example.com/mcp"]),
        /AMN dev or int/,
    );
    assert.throws(
        () =>
            parseArguments([
                "--url",
                "https://api.dev.amnhealthcare.io/ai/new-relic-mcp/dev",
                "--audience",
                "api://other",
            ]),
        /AMN New Relic MCP Entra application/,
    );
});

test("Azure token provider caches until five minutes before JWT expiry", async () => {
    let currentTime = 1_800_000_000_000;
    const expirySeconds = currentTime / 1000 + 3600;
    let calls = 0;
    const provider = createAzureTokenProvider({
        audience: DEFAULT_AUDIENCE,
        now: () => currentTime,
        runAz: async (args) => {
            calls += 1;
            assert.deepEqual(args.slice(0, 4), [
                "account",
                "get-access-token",
                "--resource",
                DEFAULT_AUDIENCE,
            ]);
            return { stdout: `${jwtWithExpiry(expirySeconds)}\n` };
        },
    });

    const first = await provider.get();
    assert.equal(await provider.get(), first);
    assert.equal(calls, 1);

    currentTime = (expirySeconds - 4 * 60) * 1000;
    await provider.get();
    assert.equal(calls, 2);
});

test("authenticated fetch refreshes once after an authorization failure", async () => {
    const requestedTokens = [];
    let clearCalls = 0;
    const tokenProvider = {
        clear() {
            clearCalls += 1;
        },
        async get({ forceRefresh }) {
            const token = forceRefresh ? "fresh-token" : "cached-token";
            requestedTokens.push({ forceRefresh, token });
            return token;
        },
    };
    const requests = [];
    const authenticatedFetch = createAuthenticatedFetch({
        tokenProvider,
        fetchImplementation: async (_input, init) => {
            requests.push(init);
            return new Response(null, { status: requests.length === 1 ? 401 : 200 });
        },
    });

    const response = await authenticatedFetch("https://example.test/mcp", {
        headers: { "X-Correlation-ID": "test" },
    });

    assert.equal(response.status, 200);
    assert.equal(requests.length, 2);
    assert.equal(clearCalls, 1);
    assert.deepEqual(requestedTokens, [
        { forceRefresh: false, token: "cached-token" },
        { forceRefresh: true, token: "fresh-token" },
    ]);
    assert.equal(requests[0].headers.get("Authorization"), "Bearer cached-token");
    assert.equal(requests[1].headers.get("Authorization"), "Bearer fresh-token");
    assert.equal(requests[1].headers.get("X-Correlation-ID"), "test");
    assert.equal(requests[1].redirect, "error");
});
