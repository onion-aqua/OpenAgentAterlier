import { build } from 'esbuild';
import { cp, mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.dirname(fileURLToPath(import.meta.url));
const frameworkRoot = path.join(root, 'vendor', 'framework');
const outputRoot = path.join(root, '..', 'assets', 'web');
const bundlePath = path.join(outputRoot, 'flutter_live2d_web.js');

await mkdir(outputRoot, { recursive: true });
await build({
  entryPoints: [path.join(root, 'src', 'runtime.ts')],
  bundle: true,
  format: 'iife',
  target: ['es2020'],
  outfile: bundlePath,
  legalComments: 'inline',
  plugins: [
    {
      name: 'cubism-framework-alias',
      setup(buildApi) {
        buildApi.onResolve({ filter: /^@framework\// }, args => ({
          path: path.join(
            frameworkRoot,
            'src',
            `${args.path.slice('@framework/'.length)}.ts`
          )
        }));
      }
    }
  ]
});

const bundle = await readFile(bundlePath, 'utf8');
await writeFile(bundlePath, bundle.replace(/^[ \t]+$/gm, ''), 'utf8');

await cp(
  path.join(frameworkRoot, 'Shaders', 'WebGL'),
  path.join(outputRoot, 'shaders'),
  { recursive: true, force: true }
);
