export interface Config {
  port: number;
  /** Esplora-compatible upstream, e.g. https://mempool.space/api or a self-hosted esplora. */
  esploraUpstream: string;
  /** mempool.space-style base (for /v1/fees/recommended). Optional; falls back to esplora fee-estimates. */
  mempoolUpstream: string | undefined;
  feeCacheSeconds: number;
  /**
   * Apple app identifiers (TEAMID.bundle.id) allowed to use this domain for
   * passkeys — served in the AASA file. Include the Messages extension's id;
   * that's the binary making the WebAuthn calls.
   */
  appleAppIds: string[];
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  return {
    port: Number(env.PORT ?? 3040),
    esploraUpstream: (env.ESPLORA_UPSTREAM ?? "https://mempool.space/api").replace(/\/$/, ""),
    mempoolUpstream: env.MEMPOOL_UPSTREAM?.replace(/\/$/, ""),
    feeCacheSeconds: Number(env.FEE_CACHE_SECONDS ?? 30),
    appleAppIds: (env.APPLE_APP_IDS ?? "")
      .split(",")
      .map((s) => s.trim())
      .filter(Boolean),
  };
}
