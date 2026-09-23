import http from 'node:http';

// Only export display data, never account IDs or credit identifiers.
export function resetSummary(rows, now = Date.now()) {
  const codex = Array.isArray(rows) ? rows.filter(row => row.provider === 'codex') : [];
  if (codex.length !== 1 || codex[0].error) return {state: 'unavailable'};
  const value = codex[0].usage?.codexResetCredits;
  if (!value || !Array.isArray(value.credits) || !Number.isInteger(value.availableCount) || value.availableCount < 0) return {state: 'unavailable'};
  const updated = Date.parse(value.updatedAt);
  if (!Number.isFinite(updated) || now - updated > 180000 || updated > now + 60000) return {state: 'unavailable'};
  if (value.credits.some(c => !c || typeof c.status !== 'string')) return {state:'unavailable'};
  const available = value.credits.filter(c => c.status === 'available');
  if (available.some(c => c.expires_at != null && !Number.isFinite(Date.parse(c.expires_at)))) return {state: 'unavailable'};
  const expirations = available.filter(c => c.expires_at == null || Date.parse(c.expires_at) > now)
    .map(c => c.expires_at == null ? null : new Date(c.expires_at).toISOString())
    .sort((a,b) => a === null ? 1 : b === null ? -1 : a.localeCompare(b));
  // Counts without detailed inventory are not sufficient to enumerate expiration dates.
  if (value.availableCount > available.length) return {state: 'unavailable'};
  return {state: 'available', count: expirations.length, expirations, updatedAt: value.updatedAt};
}

export function createResetReader(port) {
  let pending;
  let cached;
  let expires = 0;
  return async () => {
    if (cached && Date.now() < expires) return resetSummary(cached);
    if (!pending) pending = new Promise(resolve => {
      const request = http.get({hostname:'127.0.0.1',port,path:'/usage?provider=codex'}, response => {
        let size = 0;
        const chunks = [];
        response.on('data', chunk => { size += chunk.length; if (size > 2 * 1024 * 1024) response.destroy(); else chunks.push(chunk); });
        response.on('error', () => resolve(null));
        response.on('end', () => {
          try { resolve(response.statusCode === 200 ? JSON.parse(Buffer.concat(chunks).toString()) : null); }
          catch { resolve(null); }
        });
      });
      request.setTimeout(5000, () => request.destroy());
      request.on('error', () => resolve(null));
    }).then(rows => { cached = rows; expires = Date.now() + 60000; return rows; }).finally(() => { pending = undefined; });
    return resetSummary(await pending);
  };
}

export function addResetSummary(snapshot, summary) {
  return {...snapshot, providers:snapshot.providers.map(provider => provider.id === 'codex'
    ? {...provider, manualResets: provider.accounts?.length || provider.error ? {state:'unavailable'} : summary} : provider)};
}

// Called from the existing renderProvider closure; no extra browser requests or secrets.
export const resetRenderer = `
function appendManualResets(card, provider) {
  if (provider.id !== 'codex' || provider._pending) return;
  const section = document.createElement('section');
  section.className = 'manual-resets';
  const value = provider.manualResets;
  const fresh = value?.state === 'available' && Date.now() - Date.parse(value.updatedAt) <= 180000;
  const expirations = fresh ? value.expirations.filter(date => date === null || Date.parse(date) > Date.now()) : [];
  if (!fresh || !expirations.length) {
    section.textContent = fresh ? 'Manual resets · 0 available' : 'Manual resets · Unavailable';
  } else {
    const details = document.createElement('details');
    const summary = document.createElement('summary');
    summary.textContent = 'Manual resets · ' + expirations.length + ' available — Expiration dates';
    const list = document.createElement('ol');
    for (const expiry of expirations) {
      const item = document.createElement('li');
      item.textContent = expiry === null ? 'No expiry' : 'Expires ' + new Date(expiry).toLocaleString(undefined, {dateStyle:'medium',timeStyle:'short'});
      list.append(item);
    }
    details.append(summary, list); section.append(details);
  }
  card.append(section);
}
`;

export function installResetRenderer(html) {
  // Match only the provider renderer, never account cards. Upstream drift fails closed.
  const start = html.indexOf('function renderProvider(provider) {');
  const end = html.indexOf('function appendCostSummary(', start);
  if (start < 0 || end < 0) return html; // Minimal test fixtures/non-dashboard pages.
  const block = html.slice(start,end);
  const position = block.lastIndexOf('return card;');
  if (position < 0) throw new Error('Unsupported provider renderer');
  return html.slice(0,start) + resetRenderer + block.slice(0,position) +
    'appendManualResets(card, provider);\n' + block.slice(position) + html.slice(end);
}
