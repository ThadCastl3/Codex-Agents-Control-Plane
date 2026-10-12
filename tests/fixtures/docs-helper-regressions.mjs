#!/usr/bin/env node
// Regression fixture. Uses only built-in Node modules and mocked fetch.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { access, mkdir, mkdtemp, readFile, realpath, rm, symlink, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const helperArg = process.argv[2];
assert.ok(helperArg, 'Usage: node tests/fixtures/docs-helper-regressions.mjs <fetch-codex-manual.mjs>');
const helperPath = await realpath(path.resolve(helperArg));
const scratch = await mkdtemp('/private/tmp/docs-helper-regressions-');
const emptyPath = path.join(scratch, 'no-external-binaries');
await mkdir(emptyPath);
const savedFetch = globalThis.fetch;
const envNames = ['PATH', 'HTTP_PROXY', 'HTTPS_PROXY', 'http_proxy', 'https_proxy'];
const savedEnv = Object.fromEntries(envNames.map((key) => [key, process.env[key]]));
const pendingTimers = new Set();
const results = [];
const manual = '# Fixture manual\n\n## Fixture heading\nFixture text.\n';
const hash = createHash('sha256').update(manual).digest('hex');
const headers = { 'x-content-sha256': hash };
const fixtureUrl = 'https://fixture.invalid/codex-manual.md';

const exists = async (target) => { try { await access(target); return true; } catch { return false; } };
const run = async (name, task) => {
  try { await task(); results.push({ name, status: 'pass' }); }
  catch (error) { results.push({ name, status: 'fail', message: error.message }); }
  finally {
    for (const timer of pendingTimers) clearTimeout(timer);
    pendingTimers.clear();
  }
};

// Return headers immediately, then stream the body after a controlled delay.
// Like native fetch, the body errors when the request's signal is aborted.
const delayedBodyResponse = (signal, delayMs, onAbort = () => {}) => {
  let timer;
  const stream = new ReadableStream({
    start(controller) {
      const abort = () => {
        if (timer) { clearTimeout(timer); pendingTimers.delete(timer); }
        onAbort();
        controller.error(signal.reason ?? new DOMException('Aborted', 'AbortError'));
      };
      if (signal.aborted) { abort(); return; }
      signal.addEventListener('abort', abort, { once: true });
      timer = setTimeout(() => {
        pendingTimers.delete(timer);
        signal.removeEventListener('abort', abort);
        controller.enqueue(new TextEncoder().encode(manual));
        controller.close();
      }, delayMs);
      pendingTimers.add(timer);
    },
  });
  return new Response(stream, { headers });
};

try {
  // Prevent an error fallback from invoking curl or using proxy configuration.
  process.env.PATH = emptyPath;
  for (const key of envNames.slice(1)) delete process.env[key];
  const { fetchCodexManual } = await import(pathToFileURL(helperPath).href);

  await run('installed-directory-symlink invokes CLI main', async () => {
    const linkedDir = path.join(scratch, 'installed-scripts');
    await symlink(path.dirname(helperPath), linkedDir, 'dir');
    const linkedHelper = path.join(linkedDir, path.basename(helperPath));
    const networkGuard = path.join(scratch, 'deny-network.cjs');
    await writeFile(networkGuard, "globalThis.fetch = () => { throw new Error('Fixture forbids network'); };\n");
    const child = spawnSync(process.execPath,
      ['--require', networkGuard, linkedHelper, '--review-invalid-argument'],
      { encoding: 'utf8', timeout: 2000, env: { ...process.env, PATH: emptyPath } });
    assert.equal(child.error, undefined, 'CLI probe must finish without spawn errors');
    assert.notEqual(child.status, 0, 'CLI through installed symlink must reject an invalid argument');
    assert.match(child.stderr, /Unknown argument: --review-invalid-argument/);
  });

  await run('request timeout aborts a streaming GET body', async () => {
    const cacheDir = path.join(scratch, 'timeout-cache');
    let aborted = false;
    const calls = [];
    globalThis.fetch = async (url, options) => {
      assert.equal(url, fixtureUrl);
      calls.push(options.method);
      if (options.method === 'HEAD') return new Response(null, { headers });
      assert.equal(options.method, 'GET');
      return delayedBodyResponse(options.signal, 250, () => { aborted = true; });
    };
    await assert.rejects(
      fetchCodexManual({ manualUrl: fixtureUrl, cacheDir, timeoutMs: 35 }),
      'Streaming body must be rejected when it exceeds the request timeout');
    assert.equal(aborted, true, 'The original request signal must stay active through the body read');
    assert.deepEqual(calls, ['HEAD', 'GET']);
    assert.equal(await exists(path.join(cacheDir, 'codex-manual.md')), false,
      'Failed download must not publish a cached manual');
  });

  await run('normal streaming download caches and subsequent HEAD is a hit', async () => {
    const cacheDir = path.join(scratch, 'normal-cache');
    const calls = [];
    globalThis.fetch = async (url, options) => {
      assert.equal(url, fixtureUrl);
      calls.push(options.method);
      if (options.method === 'HEAD') return new Response(null, { headers });
      assert.equal(options.method, 'GET');
      return delayedBodyResponse(options.signal, 10);
    };
    const initial = await fetchCodexManual({ manualUrl: fixtureUrl, cacheDir, timeoutMs: 500 });
    assert.equal(initial.status.cacheStatus, 'updated');
    assert.equal(initial.status.manualHashMatches, true);
    assert.equal(initial.status.fetchedManualSha256, hash);
    assert.equal(await readFile(initial.status.manualPath, 'utf8'), manual);
    assert.match(await readFile(initial.status.outlinePath, 'utf8'), /Fixture heading/);
    const cached = await fetchCodexManual({ manualUrl: fixtureUrl, cacheDir, timeoutMs: 500 });
    assert.equal(cached.status.cacheStatus, 'hit');
    assert.equal(cached.status.manualHashMatches, true);
    assert.deepEqual(calls, ['HEAD', 'GET', 'HEAD']);
  });
} finally {
  globalThis.fetch = savedFetch;
  for (const key of envNames) {
    if (savedEnv[key] === undefined) delete process.env[key];
    else process.env[key] = savedEnv[key];
  }
  for (const timer of pendingTimers) clearTimeout(timer);
  await rm(scratch, { recursive: true, force: true });
}
console.log(JSON.stringify(results, null, 2));
process.exitCode = results.some((result) => result.status !== 'pass') ? 1 : 0;
