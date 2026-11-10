// Anthropic rate limits the Claude OAuth usage endpoint per account, and that
// budget is shared with every Claude Code session using the same login. One
// 429 makes CodexBar back off for five minutes, during which the snapshot has
// only an error for Claude. Usage moves slowly, so show the last good reading
// (clearly marked with its age) instead of an empty card.
const RATE_LIMIT_MARKER = 'usage endpoint is rate limited';

export function createClaudeFallback({maxAgeMs = 30 * 60_000, now = Date.now} = {}) {
  let lastGood;
  return snapshot => {
    if (!Array.isArray(snapshot?.providers)) return snapshot;
    return {...snapshot, providers: snapshot.providers.map(provider => {
      if (provider?.id !== 'claude') return provider;
      if (!provider.error) {
        if (provider.windows?.length) lastGood = {provider, at: now()};
        return provider;
      }
      const age = lastGood ? now() - lastGood.at : Infinity;
      // Only mask the rate limit; auth and other failures must stay visible.
      if (!String(provider.error.message ?? '').includes(RATE_LIMIT_MARKER) || age > maxAgeMs) return provider;
      const minutes = Math.max(1, Math.round(age / 60_000));
      return {...lastGood.provider, display: provider.display ?? lastGood.provider.display,
        status: {level: 'warning', label: `rate limited · showing ${minutes}m old data`}};
    })};
  };
}
