import {build} from 'esbuild';
import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import {fileURLToPath} from 'node:url';

const root = path.dirname(fileURLToPath(import.meta.url));
const output = path.resolve(root, '../../SeekAPI/Resources/MarkdownRenderer');
await fs.mkdir(output, {recursive: true});
await build({entryPoints: [path.join(root, 'renderer.js')], outfile: path.join(output, 'renderer.js'),
  bundle: true, minify: true, format: 'iife', target: 'safari17', legalComments: 'eof', logLevel: 'info'});
await build({entryPoints: [path.join(root, 'mermaid-entry.js')], outfile: path.join(output, 'mermaid.js'),
  bundle: true, minify: true, format: 'iife', target: 'safari17', legalComments: 'eof', logLevel: 'info'});
for (const file of ['index.html', 'renderer.css']) await fs.copyFile(path.join(root, file), path.join(output, file));
await fs.copyFile(path.join(root, 'node_modules/katex/dist/katex.min.css'), path.join(output, 'katex.css'));
await fs.cp(path.join(root, 'node_modules/katex/dist/fonts'), path.join(output, 'fonts'), {recursive: true});

const lock = JSON.parse(await fs.readFile(path.join(root, 'package-lock.json'), 'utf8'));
const notices = [];
for (const [folder, entry] of Object.entries(lock.packages)) {
  if (!folder || entry.dev) continue;
  const packageRoot = path.join(root, folder);
  const pkg = JSON.parse(await fs.readFile(path.join(packageRoot, 'package.json'), 'utf8'));
  const licenses = (await fs.readdir(packageRoot)).filter(name => /^(licen[sc]e|copying|notice)(\.|$|-)/i.test(name));
  const text = await Promise.all(licenses.map(async name => {
    const file = path.join(packageRoot, name);
    return (await fs.stat(file)).isFile() ? await fs.readFile(file, 'utf8') : '';
  }));
  notices.push(`${pkg.name} ${pkg.version} (${entry.license || pkg.license || 'See upstream license'})\n${pkg.repository?.url || pkg.homepage || ''}\n${text.join('\n')}`);
}
await fs.writeFile(path.join(output, 'ThirdPartyNotices.txt'), notices.join('\n\n' + '='.repeat(78) + '\n\n'));
async function inventory(folder, prefix = '') {
  const rows = [];
  for (const item of await fs.readdir(folder, {withFileTypes: true})) {
    const relative = prefix + item.name, absolute = path.join(folder, item.name);
    if (item.isDirectory()) rows.push(...await inventory(absolute, relative + '/'));
    else if (relative !== 'manifest.json') {
      const data = await fs.readFile(absolute);
      rows.push({path: relative, bytes: data.length, sha256: crypto.createHash('sha256').update(data).digest('hex')});
    }
  }
  return rows.sort((a,b) => a.path.localeCompare(b.path));
}
const versions = Object.fromEntries(['marked','katex','dompurify','mermaid','highlight.js'].map(name => [name, lock.packages['node_modules/' + name].version]));
await fs.writeFile(path.join(output, 'manifest.json'), JSON.stringify({versions, files: await inventory(output)}, null, 2) + '\n');
console.log(`Bundled offline renderer and licenses at ${output}`);
