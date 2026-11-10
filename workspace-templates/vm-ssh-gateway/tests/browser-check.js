// Browser half of test-vm-gateway.sh. Opens the code-server app URL the
// template uses and checks, through the real UI, that the VM's folder is the
// workspace, that an edit saved in the editor lands on the VM, and that the
// default integrated terminal runs on the VM.
//
// Usage: node browser-check.js <code-server base url> <workspace file path>
// Prints one "RESULT <json>" line; the shell script asserts on it and on the
// VM's filesystem.
const { chromium } = require('playwright');

const [base, workspaceFile] = process.argv.slice(2);

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1400, height: 900 } });
  await page.goto(`${base}/?workspace=${encodeURIComponent(workspaceFile)}`, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('.monaco-workbench', { timeout: 60000 });

  // The explorer fills in once SSH FS has connected and listed the folder.
  const explorerRows = () =>
    page.$$eval('.explorer-folders-view .monaco-list-row', (rows) => rows.map((r) => r.getAttribute('aria-label')));
  let explorer = [];
  for (let i = 0; i < 60 && explorer.length < 2; i++) {
    await page.waitForTimeout(1000);
    explorer = await explorerRows();
  }

  // Quick Open depends on file search across the ssh:// folder; record
  // whether it finds the file, without failing the run on it.
  await page.keyboard.press('Control+P');
  await page.waitForTimeout(1000);
  await page.keyboard.type('VM_MARKER');
  await page.waitForTimeout(5000);
  const quickOpen = await page.$$eval('.quick-input-list .monaco-list-row', (rows) => rows.map((r) => r.getAttribute('aria-label')));
  await page.keyboard.press('Escape');

  // Edit a VM file in the editor and save it.
  await page.dblclick('.explorer-folders-view .monaco-list-row[aria-label="VM_MARKER.txt"]');
  await page.waitForSelector('.editor-instance .monaco-editor', { timeout: 20000 });
  await page.waitForTimeout(2000);
  await page.click('.editor-instance .monaco-editor .view-lines');
  await page.keyboard.press('Control+End');
  await page.keyboard.type('edited-in-code-server');
  await page.keyboard.press('Control+S');
  await page.waitForTimeout(4000);

  // Default terminal profile: should be a shell on the VM, in the folder.
  await page.keyboard.press('Control+Backquote');
  await page.waitForSelector('.terminal-wrapper .xterm', { timeout: 20000 });
  await page.waitForTimeout(8000);
  await page.keyboard.type('echo "$(hostname):$(pwd)" > ~/TERMINAL_MARKER.txt');
  await page.keyboard.press('Enter');
  await page.waitForTimeout(4000);

  const result = {
    title: await page.title(),
    explorer,
    quickOpen,
    terminalText: await page.$$eval('.xterm-rows, .xterm-accessibility-tree', (es) => es.map((e) => e.innerText.slice(0, 300))).catch(() => null),
    focus: await page.evaluate(() => document.activeElement && (document.activeElement.className || document.activeElement.tagName)),
    notifications: await page.$$eval('.notification-list-item-message', (n) => n.map((e) => e.innerText.slice(0, 200))),
  };
  console.log('RESULT ' + JSON.stringify(result));
  await browser.close();
})().catch((e) => {
  console.error('ERR ' + e.message);
  process.exit(1);
});
