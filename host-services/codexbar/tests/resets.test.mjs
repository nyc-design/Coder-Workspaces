import test from 'node:test';
import assert from 'node:assert/strict';
import {resetSummary, addResetSummary, installResetRenderer, createResetReader} from '../reset-credits.mjs';
import http from 'node:http';
const now = Date.now();
const date = offset => new Date(now + offset).toISOString();
const rows = credits => [{provider:'codex',usage:{codexResetCredits:{credits,availableCount:credits.filter(c=>c.status==='available').length,updatedAt:date(0)}}}];

test('available reset expirations sorted; expired/redeemed excluded; no expiry retained', () => {
 const input=rows([{status:'available',expires_at:date(20000)},{status:'available',expires_at:null},
 {status:'available',expires_at:date(10000)},{status:'available',expires_at:date(-10000)}, {status:'redeemed',expires_at:date(30000)}]);
 const output=resetSummary(input,now);
 assert.equal(output.count,3);assert.deepEqual(output.expirations,[date(10000),date(20000),null]);
 assert(!JSON.stringify(output).includes('reset_type'));
});
test('missing, ambiguous, stale and malformed inventory are unavailable, not zero', () => {
 for(const input of [null,[],[{provider:'codex'}],[...rows([]),...rows([])],rows([{status:'available',expires_at:'bad'}])]) assert.equal(resetSummary(input,now).state,'unavailable');
 const stale=rows([]);stale[0].usage.codexResetCredits.updatedAt=date(-181000);assert.equal(resetSummary(stale,now).state,'unavailable');
 const missing=rows([]);missing[0].usage.codexResetCredits.availableCount=2;assert.equal(resetSummary(missing,now).state,'unavailable');
 assert.equal(resetSummary(rows([]),now).count,0);
});
test('no reset inventory is attributed to ambiguous account cards or other providers',()=>{
 const snapshot={providers:[{id:'codex',accounts:[{}]},{id:'claude'}]};
 const output=addResetSummary(snapshot,{state:'available',count:3});
 assert.equal(output.providers[0].manualResets.state,'unavailable');assert.deepEqual(output.providers[1],snapshot.providers[1]);assert.equal(snapshot.providers[0].manualResets,undefined);
});
test('renderer inserted only into final provider return, with no redemption controls',()=>{
 const html='function renderProvider(provider) { if (provider._pending) return card; return card; } function appendCostSummary(';
 const result=installResetRenderer(html);assert(result.includes('appendManualResets(card, provider);\nreturn card;'));assert(result.includes('if (provider._pending) return card;'));assert(!result.includes('innerHTML'));assert(!result.includes('/redeem'));
});
test('raw usage reads are coalesced, cached and stripped of account details',async t=>{
 let calls=0;const upstream=http.createServer((req,res)=>{calls++;assert.equal(req.url,'/usage?provider=codex');res.end(JSON.stringify(rows([])));});
 await new Promise(resolve=>upstream.listen(0,'127.0.0.1',resolve));t.after(()=>{upstream.closeAllConnections();upstream.close();});
 const read=createResetReader(upstream.address().port);const result=await Promise.all([read(),read(),read()]);assert.equal(calls,1);assert(result.every(x=>x.count===0));await read();assert.equal(calls,1);
});
