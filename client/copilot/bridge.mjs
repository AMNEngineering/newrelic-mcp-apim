#!/usr/bin/env node

import { pathToFileURL } from "node:url";

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
    CallToolRequestSchema,
    ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import {
    createAuthenticatedFetch,
    createAzureTokenProvider,
    parseArguments,
} from "./auth.mjs";
import { runAzureCli } from "./azure-cli.mjs";

function log(message) {
    process.stderr.write(`[newrelic-apim] ${message}\n`);
}

export async function runBridge({ audience, azPath, url }) {
    const tokenProvider = createAzureTokenProvider({
        audience,
        runAz: (args) => runAzureCli(azPath, args),
    });
    const authenticatedFetch = createAuthenticatedFetch({ tokenProvider });
    const remoteTransport = new StreamableHTTPClientTransport(new URL(url), {
        fetch: authenticatedFetch,
    });
    const remoteClient = new Client(
        { name: "amn-newrelic-apim-bridge", version: "1.0.0" },
        { capabilities: {} },
    );

    await remoteClient.connect(remoteTransport);
    const remoteCapabilities = remoteClient.getServerCapabilities();
    if (!remoteCapabilities?.tools) {
        await remoteTransport.close();
        throw new Error("The remote New Relic MCP server did not advertise tool support.");
    }

    const localServer = new Server(
        { name: "amn-newrelic-apim-bridge", version: "1.0.0" },
        {
            capabilities: { tools: {} },
            instructions: remoteClient.getInstructions(),
        },
    );

    localServer.setRequestHandler(ListToolsRequestSchema, (request) =>
        remoteClient.listTools(request.params),
    );
    localServer.setRequestHandler(CallToolRequestSchema, (request, extra) =>
        remoteClient.callTool(request.params, undefined, { signal: extra.signal }),
    );

    const localTransport = new StdioServerTransport();
    let shutdownPromise;
    const shutdown = () => {
        if (shutdownPromise) {
            return shutdownPromise;
        }
        shutdownPromise = (async () => {
            let timeout;
            try {
                await Promise.race([
                    remoteTransport.terminateSession().catch(() => undefined),
                    new Promise((resolve) => {
                        timeout = setTimeout(resolve, 2000);
                        timeout.unref?.();
                    }),
                ]);
            } finally {
                clearTimeout(timeout);
                await Promise.allSettled([
                    localServer.close(),
                    remoteClient.close(),
                ]);
            }
        })();
        return shutdownPromise;
    };

    const stop = () => {
        void shutdown().finally(() => {
            process.exitCode = 0;
        });
    };
    process.stdin.once("end", stop);
    process.stdin.once("close", stop);
    process.once("SIGINT", stop);
    process.once("SIGTERM", stop);

    await localServer.connect(localTransport);
    log(`Connected to ${url} with delegated Entra authentication.`);
}

async function main() {
    const options = parseArguments(process.argv.slice(2));
    if (options.help) {
        process.stderr.write(
            "Usage: bridge.mjs --url <MCP URL> [--audience <Entra resource URI>] [--az-path <path>]\n",
        );
        return;
    }

    await runBridge(options);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
    main().catch((error) => {
        log(error instanceof Error ? error.message : String(error));
        process.exitCode = 1;
    });
}
