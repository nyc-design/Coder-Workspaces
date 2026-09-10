#!/usr/bin/env node
'use strict';
// npm's gltf-validator provides a JS API, not an executable. Expose that API
// as a report-to-stdout CLI with nonzero status for invalid assets/tool failures.
const fs = require('node:fs/promises');
const path = require('node:path');
const validator = require('/opt/modeling-tools/node_modules/gltf-validator');

async function main() {
  if (process.argv.length !== 3 || !/\.(gltf|glb)$/i.test(process.argv[2])) {
    console.error('Usage: gltf-validate <asset.gltf|asset.glb>');
    process.exitCode = 2;
    return;
  }
  const file = await fs.realpath(process.argv[2]);
  const root = path.dirname(file);
  const data = await fs.readFile(file);
  const report = await validator.validateBytes(new Uint8Array(data), {
    uri: path.basename(file),
    externalResourceFunction: async (uri) => {
      // Validate local assets only; never fetch remote resources. Resolve real
      // paths to keep both ../ and symlink traversal inside the asset directory.
      if (/^[a-z][a-z0-9+.-]*:/i.test(uri)) throw new Error('Remote resource URI is not supported');
      const resource = await fs.realpath(path.resolve(root, decodeURIComponent(uri)));
      const relative = path.relative(root, resource);
      if (relative === '..' || relative.startsWith('..' + path.sep) || path.isAbsolute(relative)) {
        throw new Error('Resource escapes asset directory');
      }
      return new Uint8Array(await fs.readFile(resource));
    },
  });
  console.log(JSON.stringify(report, null, 2));
  process.exitCode = report.issues.numErrors ? 1 : 0;
}
main().catch((error) => {
  console.error('gltf-validate: ' + error.message);
  process.exitCode = 2;
});
