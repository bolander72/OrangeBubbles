import { describe, expect, it } from "vitest";
import { buildApp } from "../src/app.js";
import type { Config } from "../src/config.js";
import { fromEsploraEstimates } from "../src/fees.js";
import type { FetchLike } from "../src/upstream.js";
import { isPlausibleBitcoinAddress, isRawTxHex, isTxid } from "../src/validate.js";

const TEST_ADDRESS = "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq";
const TEST_TXID = "f4184fc596403b9d638783cf57adfe4c75c605f6356fbc91338530e9831e9e16";

const config: Config = {
  port: 0,
  esploraUpstream: "https://esplora.test/api",
  mempoolUpstream: "https://mempool.test/api",
  feeCacheSeconds: 30,
  appleAppIds: ["TEAM123.com.taprootwizards.imessagewallet.MessagesExtension"],
};

function fakeFetch(routes: Record<string, { status?: number; body: string | object }>): {
  fetchImpl: FetchLike;
  calls: string[];
} {
  const calls: string[] = [];
  const fetchImpl: FetchLike = async (url) => {
    calls.push(url);
    const route = Object.entries(routes).find(([suffix]) => url.endsWith(suffix));
    if (!route) return new Response("not found", { status: 404 });
    const { status = 200, body } = route[1];
    return typeof body === "string"
      ? new Response(body, { status })
      : new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
  };
  return { fetchImpl, calls };
}

describe("validation", () => {
  it("accepts mainnet/testnet/regtest addresses", () => {
    expect(isPlausibleBitcoinAddress(TEST_ADDRESS)).toBe(true);
    expect(isPlausibleBitcoinAddress("tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx")).toBe(true);
    expect(isPlausibleBitcoinAddress("1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa")).toBe(true);
    expect(
      isPlausibleBitcoinAddress("bc1p5d7rjq7g6rdk2yhzks9smlaqtedr4dekq08ge8ztwac72sfr9rusxg3297"),
    ).toBe(true);
  });

  it("rejects garbage and path-traversal shapes", () => {
    expect(isPlausibleBitcoinAddress("../fee-estimates")).toBe(false);
    expect(isPlausibleBitcoinAddress("bc1q; rm -rf /")).toBe(false);
    expect(isPlausibleBitcoinAddress("")).toBe(false);
  });

  it("validates txids and raw tx hex", () => {
    expect(isTxid(TEST_TXID)).toBe(true);
    expect(isTxid("xyz")).toBe(false);
    expect(isRawTxHex("02".repeat(100))).toBe(true);
    expect(isRawTxHex("zz".repeat(100))).toBe(false);
    expect(isRawTxHex("02")).toBe(false);
  });
});

describe("fee normalization", () => {
  it("maps esplora confirmation-target estimates to tiers", () => {
    const fees = fromEsploraEstimates({ "1": 40.1, "3": 20.2, "6": 10.5, "144": 2.3 });
    expect(fees).toEqual({
      fastestFee: 41,
      halfHourFee: 21,
      hourFee: 11,
      economyFee: 3,
      minimumFee: 1,
    });
  });

  it("keeps tiers monotonic even when upstream is inverted", () => {
    const fees = fromEsploraEstimates({ "1": 5, "3": 9, "6": 20, "144": 30 });
    expect(fees.fastestFee).toBeGreaterThanOrEqual(fees.halfHourFee);
    expect(fees.halfHourFee).toBeGreaterThanOrEqual(fees.hourFee);
    expect(fees.hourFee).toBeGreaterThanOrEqual(fees.economyFee);
  });
});

describe("app routes", () => {
  it("serves normalized fees from the mempool upstream and caches them", async () => {
    let t = 1_000_000;
    const { fetchImpl, calls } = fakeFetch({
      "/v1/fees/recommended": {
        body: { fastestFee: 12, halfHourFee: 8, hourFee: 5, economyFee: 2, minimumFee: 1 },
      },
    });
    const app = buildApp({ config, fetchImpl, now: () => t });

    const res1 = await app.request("/v1/fees");
    expect(res1.status).toBe(200);
    expect(await res1.json()).toMatchObject({ fastestFee: 12, hourFee: 5 });

    t += 5_000; // within cache window
    await app.request("/v1/fees");
    expect(calls.length).toBe(1);

    t += 60_000; // past cache window
    await app.request("/v1/fees");
    expect(calls.length).toBe(2);
  });

  it("proxies address utxos for valid addresses", async () => {
    const utxos = [{ txid: TEST_TXID, vout: 0, value: 50_000 }];
    const { fetchImpl } = fakeFetch({ [`/address/${TEST_ADDRESS}/utxo`]: { body: utxos } });
    const app = buildApp({ config, fetchImpl });

    const res = await app.request(`/esplora/address/${TEST_ADDRESS}/utxo`);
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual(utxos);
  });

  it("rejects invalid addresses without contacting upstream", async () => {
    const { fetchImpl, calls } = fakeFetch({});
    const app = buildApp({ config, fetchImpl });

    const res = await app.request("/esplora/address/not-an-address/utxo");
    expect(res.status).toBe(400);
    expect(calls.length).toBe(0);
  });

  it("broadcasts valid raw tx hex and returns the txid", async () => {
    const { fetchImpl } = fakeFetch({ "/tx": { body: `${TEST_TXID}\n` } });
    const app = buildApp({ config, fetchImpl });

    const res = await app.request("/esplora/tx", { method: "POST", body: "02".repeat(100) });
    expect(res.status).toBe(200);
    expect(await res.text()).toBe(TEST_TXID);
  });

  it("passes through upstream rejection of a bad broadcast", async () => {
    const { fetchImpl } = fakeFetch({
      "/tx": { status: 400, body: "sendrawtransaction RPC error: min relay fee not met" },
    });
    const app = buildApp({ config, fetchImpl });

    const res = await app.request("/esplora/tx", { method: "POST", body: "02".repeat(100) });
    expect(res.status).toBe(400);
    expect(await res.text()).toContain("min relay fee");
  });

  it("rejects malformed broadcast bodies without contacting upstream", async () => {
    const { fetchImpl, calls } = fakeFetch({});
    const app = buildApp({ config, fetchImpl });

    const res = await app.request("/esplora/tx", { method: "POST", body: "hello" });
    expect(res.status).toBe(400);
    expect(calls.length).toBe(0);
  });

  it("serves the AASA file for passkey domain association", async () => {
    const { fetchImpl } = fakeFetch({});
    const app = buildApp({ config, fetchImpl });

    const res = await app.request("/.well-known/apple-app-site-association");
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("application/json");
    expect(await res.json()).toEqual({
      webcredentials: { apps: ["TEAM123.com.taprootwizards.imessagewallet.MessagesExtension"] },
    });
  });

  it("returns 503 from AASA route when app ids are not configured", async () => {
    const { fetchImpl } = fakeFetch({});
    const app = buildApp({ config: { ...config, appleAppIds: [] }, fetchImpl });

    const res = await app.request("/.well-known/apple-app-site-association");
    expect(res.status).toBe(503);
  });

  it("proxies tx status", async () => {
    const status = { confirmed: true, block_height: 900_000 };
    const { fetchImpl } = fakeFetch({ [`/tx/${TEST_TXID}/status`]: { body: status } });
    const app = buildApp({ config, fetchImpl });

    const res = await app.request(`/esplora/tx/${TEST_TXID}/status`);
    expect(await res.json()).toEqual(status);
  });
});
