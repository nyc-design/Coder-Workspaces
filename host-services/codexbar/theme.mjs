// Local, dependency-free brand mark; no external assets or tracking requests.
export const brandName = 'Tapiavala AI Usage';
const mark = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 40 40"><rect width="40" height="40" rx="12" fill="#151d22"/><path d="M10 12h20M20 12v18" fill="none" stroke="#48ddca" stroke-width="4" stroke-linecap="round"/><path d="m27 23 3-5 3 5-3 5z" fill="#bdff6a"/></svg>';
const icon = `data:image/svg+xml,${encodeURIComponent(mark)}`;
const css = `
:root[data-theme="light"]{color-scheme:light;--page:#eef3f1;--surface:#fff;--surface-muted:#f3f7f5;--text:#17272b;--muted:#536a70;--line:#d6e3df;--shadow:0 12px 36px #102c2310;--ok:#14765b;--warning:#a65b00;--critical:#c1324b;--unknown:#61767c;--brand:#007f73;--neon:#466b0c}
:root,:root[data-theme="dark"]{color-scheme:dark;--page:#202224;--surface:#2b2e30;--surface-muted:#252729;--text:#ecf5f3;--muted:#9cafaF;--line:#424749;--shadow:0 16px 40px #0004;--ok:#6de3ad;--warning:#ffc46b;--critical:#ff8091;--unknown:#91a4ae;--brand:#48ddca;--neon:#bdff6a}
body{background:radial-gradient(ellipse at 12% 0%,color-mix(in srgb,var(--brand),transparent 88%),transparent 48%),var(--page);font-family:Inter,ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;-webkit-font-smoothing:antialiased}
.shell{padding-top:34px}.topbar{position:relative;padding-bottom:22px;border-bottom:1px solid var(--line);margin-bottom:26px}.brand{gap:13px}.brand h1{font-size:clamp(17px,2.2vw,23px);font-weight:750;letter-spacing:-.04em}.mark{flex:none;width:38px;height:38px;border:0;border-radius:12px;background:center/contain no-repeat url("${icon}");box-shadow:0 0 22px color-mix(in srgb,var(--brand),transparent 85%)}.mark::after{display:none}
.grid{gap:18px}.card,.notice{border-radius:18px}.card{padding:21px;border-top:2px solid color-mix(in srgb,var(--accent),var(--line) 55%);transition:border-color .18s,box-shadow .18s}.card:hover{border-color:color-mix(in srgb,var(--accent),var(--line) 50%)}.provider-name{letter-spacing:-.02em}.provider-icon{width:20px;height:20px}.identity{margin-bottom:18px}.windows{gap:17px}.window-head{gap:12px;margin-bottom:8px}.window-label{font-variant-numeric:tabular-nums}.window-time{color:var(--muted);font-variant-numeric:tabular-nums}.track{height:8px;background:var(--line)}.fill{background:linear-gradient(90deg,color-mix(in srgb,var(--accent),#000 12%),var(--accent));box-shadow:0 0 10px color-mix(in srgb,var(--accent),transparent 75%)}
button{border-radius:10px;padding:8px 12px;transition:border-color .15s,background .15s}button:hover{border-color:var(--brand)}button:focus-visible,input:focus-visible{outline:2px solid var(--brand);outline-offset:3px}.auth-actions button{background:var(--brand);color:var(--page);border-color:var(--brand)}.auth-actions input{border-radius:10px;padding:11px}.group-title{letter-spacing:.12em}.badge{border-radius:8px}.version{font-variant-numeric:tabular-nums}.version::before{content:"POWERED BY CODEXBAR · ";font-size:9px;letter-spacing:.06em}.pill.active{color:var(--neon);border-color:var(--neon)}
.topbar::after{content:"";position:absolute;bottom:-1px;left:0;width:100%;height:2px;background:linear-gradient(90deg,#48ddca,#bdff6a 55%,transparent)}
.brand h1{color:var(--brand)}.group-title{color:var(--brand)}.theme-toggle{display:inline-flex;align-items:center;gap:8px;flex-shrink:0;background:var(--surface-muted);border:1px solid var(--brand);color:var(--text);font-size:12px;font-weight:650}.theme-toggle::before{content:"";width:7px;height:7px;border-radius:50%;background:#bdff6a;box-shadow:0 0 8px #bdff6a66}.theme-toggle:hover{background:color-mix(in srgb,var(--brand),var(--surface) 90%)}.auth-actions button{background:linear-gradient(110deg,#48ddca,#bdff6a);color:#14221d;border:0}.mark{box-shadow:0 0 24px #48ddca30}
@media(max-width:600px){.shell{padding:20px 14px}.topbar{align-items:flex-start;flex-wrap:wrap}.brand{flex-wrap:wrap}.card{padding:18px}.auth-actions{flex-wrap:wrap}.auth-actions input{flex-basis:100%}}
@media(prefers-reduced-motion:reduce){*,*::before,*::after{animation:none!important;transition:none!important}}
`;

// Runs in the head to avoid a light flash before the stored preference is applied.
export const themeScript = `(() => {
  const key = 'tapiavala-ui-theme';
  let theme = 'dark';
  try { const saved = localStorage.getItem(key); if (saved === 'light' || saved === 'dark') theme = saved; } catch {}
  document.documentElement.dataset.theme = theme;
  document.addEventListener('DOMContentLoaded', () => {
    const button = document.getElementById('tapiavala-theme-toggle');
    if (!button) return;
    const update = () => {
      const dark = document.documentElement.dataset.theme === 'dark';
      button.textContent = dark ? 'Light mode' : 'Dark mode';
      button.setAttribute('aria-label', dark ? 'Switch to light theme' : 'Switch to dark theme');
    };
    button.addEventListener('click', () => {
      theme = document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark';
      document.documentElement.dataset.theme = theme;
      try { localStorage.setItem(key, theme); } catch {}
      update();
    });
    update();
  });
})();`;

export function brandDashboard(html) {
  if (!html.includes('<h1>CodexBar</h1>') || !html.includes('</head>')) {
    throw new Error('Unsupported dashboard markup');
  }
  return html.replace('<title>CodexBar Dashboard</title>', `<title>${brandName}</title>`)
    .replace('<h1>CodexBar</h1>', `<h1>${brandName}</h1><button type="button" class="theme-toggle" id="tapiavala-theme-toggle" aria-label="Switch to light theme">Light mode</button>`)
    .replace('Enter the bearer token configured for this CodexBar server.', 'Enter your Tapiavala AI Usage access token.')
    .replace('<link rel="icon" href="data:,">', `<link rel="icon" href="${icon}">`)
    .replace('</head>', `<style id="tapiavala-theme">${css}</style><script id="tapiavala-theme-script">${themeScript}</script></head>`);
}

export function colorProviders(snapshot) {
  const colors = {codex:'#22bfae', claude:'#e89c65', llmproxy:'#a2cf43'};
  return {...snapshot, providers:snapshot.providers.map(provider => colors[provider.id]
    ? {...provider, display:{...provider.display, accentColor:colors[provider.id]}} : provider)};
}
