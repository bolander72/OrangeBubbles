import { Hono } from "hono";
import type { Config } from "./config.js";
import { FeeService } from "./fees.js";
import type { FetchLike } from "./upstream.js";
import { EsploraUpstream, UpstreamError } from "./upstream.js";
import { isPlausibleBitcoinAddress, isRawTxHex, isTxid } from "./validate.js";

export interface AppDeps {
  config: Config;
  fetchImpl?: FetchLike;
  now?: () => number;
}

/**
 * Two route groups:
 *
 *   /v1/fees            — normalized fee tiers for the client UI
 *   /esplora/*          — strict allowlisted subset of the Esplora API, so the
 *                         iOS client's BDK EsploraClient can point at this
 *                         server instead of a public provider with zero client
 *                         changes. No keys, no seeds, no accounts, no logging
 *                         of address→IP mappings beyond default access logs.
 */
export function buildApp(deps: AppDeps): Hono {
  const { config } = deps;
  const esplora = new EsploraUpstream(config.esploraUpstream, deps.fetchImpl);
  const feeService = new FeeService(esplora, {
    mempoolUpstream: config.mempoolUpstream,
    cacheSeconds: config.feeCacheSeconds,
    ...(deps.fetchImpl ? { fetchImpl: deps.fetchImpl } : {}),
    ...(deps.now ? { now: deps.now } : {}),
  });

  const app = new Hono();

  app.onError((err, c) => {
    if (err instanceof UpstreamError) {
      // Esplora reports user errors (bad address, rejected tx) as 4xx text bodies.
      const status = err.status >= 400 && err.status < 500 ? err.status : 502;
      return c.text(err.body, status as 400);
    }
    console.error(err);
    return c.json({ error: "internal_error" }, 500);
  });

  app.get("/healthz", (c) => c.json({ ok: true }));

  // Apple App Site Association — required for the wallet passkey (PRF) to be
  // scoped to this domain. This is the only thing the domain *must* serve;
  // everything else in this server is optional.
  app.get("/.well-known/apple-app-site-association", (c) => {
    if (config.appleAppIds.length === 0) {
      return c.json({ error: "APPLE_APP_IDS not configured" }, 503);
    }
    return c.json({ webcredentials: { apps: config.appleAppIds } });
  });

  app.get("/v1/fees", async (c) => c.json(await feeService.recommended()));

  const ex = new Hono();

  ex.get("/blocks/tip/height", async (c) => c.text(await esplora.tipHeight()));
  ex.get("/fee-estimates", async (c) => c.json(await esplora.feeEstimates()));

  ex.get("/address/:address", async (c) => {
    const address = c.req.param("address");
    if (!isPlausibleBitcoinAddress(address)) return c.text("invalid address", 400);
    return c.json(await esplora.addressInfo(address));
  });

  ex.get("/address/:address/utxo", async (c) => {
    const address = c.req.param("address");
    if (!isPlausibleBitcoinAddress(address)) return c.text("invalid address", 400);
    return c.json(await esplora.addressUtxos(address));
  });

  ex.get("/address/:address/txs", async (c) => {
    const address = c.req.param("address");
    if (!isPlausibleBitcoinAddress(address)) return c.text("invalid address", 400);
    return c.json(await esplora.addressTxs(address));
  });

  ex.get("/address/:address/txs/chain/:afterTxid", async (c) => {
    const address = c.req.param("address");
    const afterTxid = c.req.param("afterTxid");
    if (!isPlausibleBitcoinAddress(address)) return c.text("invalid address", 400);
    if (!isTxid(afterTxid)) return c.text("invalid txid", 400);
    return c.json(await esplora.addressTxs(address, afterTxid));
  });

  ex.get("/tx/:txid", async (c) => {
    const txid = c.req.param("txid");
    if (!isTxid(txid)) return c.text("invalid txid", 400);
    return c.json(await esplora.tx(txid));
  });

  ex.get("/tx/:txid/status", async (c) => {
    const txid = c.req.param("txid");
    if (!isTxid(txid)) return c.text("invalid txid", 400);
    return c.json(await esplora.txStatus(txid));
  });

  ex.get("/tx/:txid/hex", async (c) => {
    const txid = c.req.param("txid");
    if (!isTxid(txid)) return c.text("invalid txid", 400);
    return c.text(await esplora.txHex(txid));
  });

  ex.post("/tx", async (c) => {
    const raw = (await c.req.text()).trim();
    if (!isRawTxHex(raw)) return c.text("invalid raw transaction hex", 400);
    return c.text(await esplora.broadcast(raw));
  });

  app.route("/esplora", ex);
  return app;
}
