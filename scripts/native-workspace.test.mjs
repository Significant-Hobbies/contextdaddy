import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

// Repeatable native verification for CodeVetter's node-test adapter. The actual
// assertions remain in Swift; this runner executes them through XcodeBuildMCP.
test('native resources, Memory recovery and workspace widths', { timeout: 118_000 }, () => {
  const root = fileURLToPath(new URL('../', import.meta.url));
  const result = spawnSync('npx', [
    '--offline', 'xcodebuildmcp', 'swift-package', 'test', '--package-path', root,
    '--filter', 'ContextUIResourcesTests|MemoryManagementTests|rootKeepsSkillsInsideTheActualWindow',
  ], { cwd: root, encoding: 'utf8', timeout: 115_000, maxBuffer: 16 * 1024 * 1024 });

  const output = `${result.stdout ?? ''}\n${result.stderr ?? ''}`;
  process.stdout.write(output);
  assert.ifError(result.error);
  assert.equal(result.status, 0, 'XcodeBuildMCP native test command failed');
  const summary = output.replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, '')
    .match(/(\d+)\s+tests?\s+passed,\s*(\d+)\s+failed/);
  assert.ok(summary, 'XcodeBuildMCP did not report a completed native test run');
  assert.ok(Number(summary[1]) >= 5, 'Expected resources, Memory and workspace checks to execute');
  assert.equal(Number(summary[2]), 0, 'Native checks reported failures');
});
