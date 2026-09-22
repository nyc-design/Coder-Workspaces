// Local, dependency-free brand mark; no external assets or tracking requests.
export const brandName = 'Tapiavala AI Usage';
const mark = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 40 40"><rect width="40" height="40" rx="12" fill="#151d22"/><path d="M10 12h20M20 12v18" fill="none" stroke="#48ddca" stroke-width="4" stroke-linecap="round"/><path d="m27 23 3-5 3 5-3 5z" fill="#bdff6a"/></svg>';
const icon = `data:image/svg+xml,${encodeURIComponent(mark)}`;
const css = `
:root{--page:#eef3f1;--surface:#fff;--surface-muted:#f3f7f5;--text:#17272b;--muted:#536a70;--line:#d6e3df;--shadow:0 12px 36px #102c2310;--ok:#14765b;--warning:#a65b00;--critical:#c1324b;--unknown:#61767c;--brand:#007f73;--neon:#466b0c}
@media(prefers-color-scheme:dark){:root{--page:#0d1216;--surface:#171f25;--surface-muted:#11191e;--text:#ecf5f3;--muted:#9cafaF;--line:#2b3b40;--shadow:0 16px 40px #0004;--ok:#6de3ad;--warning:#ffc46b;--critical:#ff8091;--unknown:#91a4ae;--brand:#48ddca;--neon:#bdff6a}}
body{background:radial-gradient(ellipse at 12% 0%,color-mix(in srgb,var(--brand),transparent 93%),transparent 55%),var(--page);font-family:Inter,ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;-webkit-font-smoothing:antialiased}
.shell{padding-top:34px}.topbar{padding-bottom:22px;border-bottom:1px solid var(--line);margin-bottom:26px}.brand{gap:13px}.brand h1{font-size:clamp(17px,2.2vw,23px);font-weight:750;letter-spacing:-.04em}.mark{flex:none;width:38px;height:38px;border:0;border-radius:12px;background:center/contain no-repeat url("${icon}");box-shadow:0 0 22px color-mix(in srgb,var(--brand),transparent 85%)}.mark::after{display:none}
.grid{gap:18px}.card,.notice{border-radius:18px}.card{padding:21px;border-top:2px solid color-mix(in srgb,var(--accent),var(--line) 55%);transition:border-color .18s,box-shadow .18s}.card:hover{border-color:color-mix(in srgb,var(--accent),var(--line) 50%)}.provider-name{letter-spacing:-.02em}.provider-icon{width:20px;height:20px}.identity{margin-bottom:18px}.windows{gap:17px}.window-head{gap:12px;margin-bottom:8px}.window-label{font-variant-numeric:tabular-nums}.window-time{color:var(--muted);font-variant-numeric:tabular-nums}.track{height:8px;background:var(--line)}.fill{background:linear-gradient(90deg,color-mix(in srgb,var(--accent),#000 12%),var(--accent));box-shadow:0 0 10px color-mix(in srgb,var(--accent),transparent 75%)}
button{border-radius:10px;padding:8px 12px;transition:border-color .15s,background .15s}button:hover{border-color:var(--brand)}button:focus-visible,input:focus-visible{outline:2px solid var(--brand);outline-offset:3px}.auth-actions button{background:var(--brand);color:var(--page);border-color:var(--brand)}.auth-actions input{border-radius:10px;padding:11px}.group-title{letter-spacing:.12em}.badge{border-radius:8px}.version{font-variant-numeric:tabular-nums}.version::before{content:"POWERED BY CODEXBAR · ";font-size:9px;letter-spacing:.06em}.pill.active{color:var(--neon);border-color:var(--neon)}
@media(max-width:600px){.shell{padding:20px 14px}.topbar{align-items:flex-start;flex-wrap:wrap}.brand{flex-wrap:wrap}.card{padding:18px}.auth-actions{flex-wrap:wrap}.auth-actions input{flex-basis:100%}}
@media(prefers-reduced-motion:reduce){*,*::before,*::after{animation:none!important;transition:none!important}}
`;

export function brandDashboard(html) {
  if (!html.includes('<h1>CodexBar</h1>') || !html.includes('</head>')) {
    throw new Error('Unsupported dashboard markup');
  }
  return html.replace('<title>CodexBar Dashboard</title>', `<title>${brandName}</title>`)
    .replace('<h1>CodexBar</h1>', `<h1>${brandName}</h1>`)
    .replace('Enter the bearer token configured for this CodexBar server.', 'Enter your Tapiavala AI Usage access token.')
    .replace('<link rel="icon" href="data:,">', `<link rel="icon" href="${icon}">`)
    .replace('</head>', `<style id="tapiavala-theme">${css}</style></head>`);
}

export function colorProviders(snapshot) {
  const colors = {codex:'#22bfae', claude:'#e89c65', llmproxy:'#a2cf43'};
  return {...snapshot, providers:snapshot.providers.map(provider => colors[provider.id]
    ? {...provider, display:{...provider.display, accentColor:colors[provider.id]}} : provider)};
}
