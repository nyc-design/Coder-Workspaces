// Observe only the known usage response, before Bailian drops monthly fields.
// FD 3 is a private pipe to the bridge; never forward credentials or raw payloads.
const fs = require('node:fs');
const originalFetch = globalThis.fetch;
globalThis.fetch = async (...args) => {
  const response = await originalFetch(...args);
  const url = new URL(String(args[0]));
  if (url.pathname === '/cli/api.json' &&
      url.searchParams.get('api') === 'zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage' && response.ok) {
    const envelope = await response.clone().json();
    const result = envelope?.data?.DataV2?.data;
    const usage = result?.data;
    if (envelope.successResponse === true && envelope.data.success === true && result.success === true &&
        typeof usage?.per1MonthPercentage === 'number' && typeof usage?.per1MonthResetTime === 'number') {
      fs.writeSync(3, JSON.stringify({ratio: usage.per1MonthPercentage, reset: usage.per1MonthResetTime}));
    }
  }
  return response;
};
