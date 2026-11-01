// Real Claude Code -> isolated Anthropic mock. No proxy or real credential is used.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import os from 'node:os';

// Optional diagnostic only: Node 18+, Windows, and an installed native Claude Code binary.
// --help does not start the mock or Claude Code. Generated evidence goes outside the repo.
if (process.argv.includes('--help')) {
  console.log('Usage: node tests/Probe-NativeCliEffort.mjs --claude-path <absolute claude.exe path> [--output-dir <empty evidence directory>]');
  console.log('Runs ten short CLI requests against a loopback-only mock using a fake key; no real upstream or login.');
  process.exit(0);
}
const options = {};
for (let index = 2; index < process.argv.length; index += 2) {
  const name = process.argv[index];
  const value = process.argv[index + 1];
  if (!['--claude-path', '--output-dir'].includes(name) || !value || value.startsWith('--')) {
    throw new Error('Use --claude-path <path> and optionally --output-dir <empty directory>; see --help.');
  }
  if (Object.hasOwn(options, name)) throw new Error(`Duplicate option: ${name}`);
  options[name] = value;
}
if (!options['--claude-path'] || !path.isAbsolute(options['--claude-path'])) {
  throw new Error('--claude-path must name the absolute path to your installed native Claude Code binary.');
}
if (process.platform !== 'win32') throw new Error('This diagnostic supports Windows only.');
const claudePath = path.resolve(options['--claude-path']);
if (!fs.statSync(claudePath).isFile()) throw new Error('The requested Claude Code binary is not a file.');
const outputRoot = options['--output-dir']
  ? path.resolve(options['--output-dir'])
  : fs.mkdtempSync(path.join(os.tmpdir(), 'claude-native-effort-probe-'));
if (fs.existsSync(outputRoot) && fs.readdirSync(outputRoot).length) {
  throw new Error('--output-dir must be empty so previous evidence is never overwritten.');
}
const models = ['gpt-6.1-sol', 'local-claude-sol'];
const levels = ['low', 'medium', 'high', 'xhigh', 'max'];
const syntheticText = 'NATIVE_CLI_EFFORT_MOCK_OK';
const requests = [];
let currentCase = null;
fs.mkdirSync(outputRoot, { recursive: true });

const mock = http.createServer((req, res) => {
  const route = new URL(req.url, 'http://127.0.0.1').pathname;
  let body = '';
  req.setEncoding('utf8');
  req.on('data', chunk => { body += chunk; });
  req.on('end', () => {
    let payload = {};
    try { payload = JSON.parse(body || '{}'); } catch {}
    body = '';
    requests.push({
      caseId: currentCase,
      route,
      method: req.method,
      model: payload.model ?? null,
      outputConfigEffort: payload.output_config?.effort ?? null,
      topLevelEffort: payload.effort ?? null,
      reasoningEffort: payload.reasoning?.effort ?? null,
      thinkingType: payload.thinking?.type ?? null,
      thinkingBudgetTokens: payload.thinking?.budget_tokens ?? null,
      maxTokens: payload.max_tokens ?? null,
      stream: payload.stream ?? null
    });
    if (route === '/v1/messages/count_tokens') {
      res.writeHead(200, { 'content-type': 'application/json' });
      return res.end(JSON.stringify({ input_tokens: 10 }));
    }
    if (route !== '/v1/messages') {
      res.writeHead(404, { 'content-type': 'application/json' });
      return res.end(JSON.stringify({ type: 'error', error: { type: 'not_found_error', message: 'Local mock does not forward requests.' } }));
    }
    const message = { id: 'msg_native_cli_effort_mock', type: 'message', role: 'assistant', model: payload.model, content: [{ type: 'text', text: syntheticText }], stop_reason: 'end_turn', stop_sequence: null, usage: { input_tokens: 10, output_tokens: 8 } };
    if (!payload.stream) {
      res.writeHead(200, { 'content-type': 'application/json' });
      return res.end(JSON.stringify(message));
    }
    res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' });
    const events = [
      ['message_start', { type: 'message_start', message: { ...message, content: [], stop_reason: null, usage: { input_tokens: 10, output_tokens: 0 } } }],
      ['content_block_start', { type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } }],
      ['content_block_delta', { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: syntheticText } }],
      ['content_block_stop', { type: 'content_block_stop', index: 0 }],
      ['message_delta', { type: 'message_delta', delta: { stop_reason: 'end_turn', stop_sequence: null }, usage: { output_tokens: 8 } }],
      ['message_stop', { type: 'message_stop' }]
    ];
    for (const [name, data] of events) res.write(`event: ${name}\ndata: ${JSON.stringify(data)}\n\n`);
    res.end();
  });
});
mock.on('connect', (req, socket) => {
  requests.push({ caseId: currentCase, route: req.url, method: 'CONNECT', blocked: true });
  socket.end('HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n');
});
await new Promise(resolve => mock.listen(0, '127.0.0.1', resolve));
const endpoint = `http://127.0.0.1:${mock.address().port}`;
const report = {
  kind: 'Real installed Claude Code native --effort -> loopback Anthropic mock',
  startedAtUtc: new Date().toISOString(),
  outputRoot,
  cliPath: claudePath,
  baseUrl: endpoint,
  models,
  levels,
  realCredentialsLoaded: false,
  realProxyUsed: false,
  upstreamForwardingImplemented: false,
  cases: []
};

try {
  for (const model of models) for (const level of levels) {
    const caseId = `${model}--${level}`;
    currentCase = caseId;
    const profile = path.join(outputRoot, 'profiles', caseId);
    fs.mkdirSync(profile, { recursive: true });
    const env = { ...process.env };
    for (const key of Object.keys(env)) {
      if (/^(ANTHROPIC_|CLAUDE_|AWS_|AZURE_|GOOGLE_|GEMINI_|OPENAI_)/i.test(key) || /proxy$/i.test(key) || key === 'MAX_THINKING_TOKENS') delete env[key];
    }
    Object.assign(env, {
      ANTHROPIC_BASE_URL: endpoint,
      ANTHROPIC_AUTH_TOKEN: 'offline-native-effort-mock-only',
      CLAUDE_CONFIG_DIR: profile,
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1',
      CLAUDE_CODE_DISABLE_BACKGROUND_TASKS: '1',
      CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY: '0',
      DISABLE_TELEMETRY: '1',
      DISABLE_ERROR_REPORTING: '1',
      DISABLE_AUTOUPDATER: '1',
      HTTP_PROXY: endpoint,
      HTTPS_PROXY: endpoint,
      ALL_PROXY: endpoint,
      NO_PROXY: '127.0.0.1,localhost'
    });
    const args = ['-p', `Reply exactly ${syntheticText}. Do not call any tools.`, '--model', model, '--effort', level, '--output-format', 'stream-json', '--verbose', '--safe-mode', '--strict-mcp-config', '--no-session-persistence', '--max-turns', '1', '--permission-prompts', 'none', '--tools', ''];
    const started = Date.now();
    const child = spawn(claudePath, args, { cwd: outputRoot, env, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '', stderr = '';
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', chunk => { stdout += chunk; });
    child.stderr.on('data', chunk => { stderr += chunk; });
    let timedOut = false;
    const timer = setTimeout(() => { timedOut = true; child.kill(); }, 30000);
    const exitCode = await new Promise((resolve, reject) => { child.on('error', reject); child.on('close', resolve); });
    clearTimeout(timer);
    const events = stdout.split(/\r?\n/).flatMap(line => { try { return [JSON.parse(line)]; } catch { return []; } });
    const result = events.findLast(event => event.type === 'result');
    const inferenceRequests = requests.filter(request => request.caseId === caseId && request.route === '/v1/messages');
    const entry = {
      caseId,
      requestedModel: model,
      requestedNativeEffort: level,
      exitCode,
      timedOut,
      seconds: Math.round((Date.now() - started) / 10) / 100,
      resultSubtype: result?.subtype ?? null,
      mockReplyMatched: result?.result?.trim() === syntheticText,
      inferenceRequests,
      nativeEffortTransmittedExactly: inferenceRequests.length > 0 && inferenceRequests.every(request => request.outputConfigEffort === level),
      stderr
    };
    report.cases.push(entry);
    fs.writeFileSync(path.join(outputRoot, 'native-cli-effort-results.json'), JSON.stringify(report, null, 2));
    console.log(JSON.stringify({ caseId, exitCode, timedOut, observedEfforts: inferenceRequests.map(request => request.outputConfigEffort), resultSubtype: entry.resultSubtype, exact: entry.nativeEffortTransmittedExactly }));
  }
} catch (error) {
  report.failure = error.message;
} finally {
  currentCase = null;
  await new Promise(resolve => mock.close(resolve));
  report.finishedAtUtc = new Date().toISOString();
  report.mockStopped = true;
  report.nonInferenceRequests = requests.filter(request => request.route !== '/v1/messages');
  report.allTenNativeEffortsTransmittedExactly = report.cases.length === 10 && report.cases.every(entry => entry.exitCode === 0 && !entry.timedOut && entry.mockReplyMatched && entry.nativeEffortTransmittedExactly);
  fs.writeFileSync(path.join(outputRoot, 'native-cli-effort-results.json'), JSON.stringify(report, null, 2));
}
console.log(JSON.stringify({ outputRoot, caseCount: report.cases.length, allTenNativeEffortsTransmittedExactly: report.allTenNativeEffortsTransmittedExactly, mockStopped: report.mockStopped, failure: report.failure ?? null }));
if (report.failure || !report.allTenNativeEffortsTransmittedExactly) process.exitCode = 1;
