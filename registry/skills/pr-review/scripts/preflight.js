#!/usr/bin/env node
'use strict';
// preflight.js — resolve platform, repo, PR number, and identity for pr-review (public mode),
// or base/branch facts for local mode. Pure resolution: no posting, no checkout.
//
//   node preflight.js <pr-ref>        pr-ref: URL | owner/repo#N | bare N | empty
//   node preflight.js --local [base]
//
// Output: one JSON object on stdout.
//   public:  { ok, mode:"public", platform, host, repo, pr, me, draftHint }
//   local:   { ok, mode:"local", branch, base, defaultBranch }
//   unresolvable: { ok:false, ask:true, reason } (exit 2) — the skill asks the user.
const { run, runJson, parseArgs, emit } = require('./lib');

const { flags, pos } = parseArgs(process.argv.slice(2));

function gitRemoteHost() {
  const r = run('git', ['remote', 'get-url', 'origin']);
  if (!r.ok) return null;
  const m = r.out.trim().match(/(?:@|:\/\/)([^/:]+)[/:]/);
  return m ? m[1] : null;
}

function platformForHost(host) {
  if (!host) return null;
  if (host === 'github.com' || /(^|\.)ghe\./.test(host)) return 'github';
  if (/gitlab/.test(host)) return 'gitlab';
  // Unknown host: whichever CLI knows it wins.
  if (run('gh', ['auth', 'status', '--hostname', host]).ok) return 'github';
  if (run('glab', ['auth', 'status', '--hostname', host], { env: { GITLAB_HOST: host } }).ok) return 'gitlab';
  return null;
}

if (flags.local) {
  const branchR = run('git', ['rev-parse', '--abbrev-ref', 'HEAD']);
  if (!branchR.ok) { emit({ ok: false, ask: true, reason: 'not a git repository' }); process.exit(2); }
  const branch = branchR.out.trim();
  let defaultBranch = null;
  const show = run('git', ['remote', 'show', 'origin']);
  if (show.ok) {
    const m = show.out.match(/HEAD branch: (\S+)/);
    if (m) defaultBranch = m[1];
  }
  let base = pos[0] || null;
  if (!base && defaultBranch) {
    base = run('git', ['rev-parse', '--verify', `origin/${defaultBranch}`]).ok
      ? `origin/${defaultBranch}` : defaultBranch;
  }
  if (!base) { emit({ ok: false, ask: true, reason: 'no base branch resolvable (no remote, detached HEAD?)' }); process.exit(2); }
  emit({ ok: true, mode: 'local', branch, base, defaultBranch });
  process.exit(0);
}

const ref = pos[0] || '';
let host = null, repo = null, pr = null, platform = null;

let m;
if ((m = ref.match(/^https?:\/\/([^/]+)\/(.+?)\/(?:-\/)?(?:pull|merge_requests)\/(\d+)/))) {
  host = m[1]; repo = m[2].replace(/\/(?:-\/)?$/, ''); pr = Number(m[3]);
} else if ((m = ref.match(/^([\w.-]+(?:\/[\w.-]+)+)([#!])(\d+)$/))) {
  // owner/repo#N is GitHub syntax; GitLab's is group/project!N — the separator is a platform signal.
  repo = m[1]; pr = Number(m[3]); platform = m[2] === '!' ? 'gitlab' : 'github';
} else if (/^\d+$/.test(ref)) {
  pr = Number(ref);
}

platform = platform || platformForHost(host);
if (!platform) { host = host || gitRemoteHost(); platform = platformForHost(host); }
if (!platform) {
  const gh = run('gh', ['auth', 'status']).ok;
  const gl = run('glab', ['auth', 'status']).ok;
  if (gh && !gl) { platform = 'github'; host = host || 'github.com'; }
  else if (gl && !gh) { platform = 'gitlab'; host = host || 'gitlab.com'; }
}
if (!platform) { emit({ ok: false, ask: true, reason: 'platform unresolvable from URL, remote, or authenticated CLIs' }); process.exit(2); }
if (!host) host = platform === 'github' ? 'github.com' : 'gitlab.com';

if (!repo) {
  if (platform === 'github') {
    const r = runJson('gh', ['repo', 'view', '--json', 'nameWithOwner']);
    if (r.ok) repo = r.json.nameWithOwner;
  } else {
    const r = run('git', ['remote', 'get-url', 'origin']);
    if (r.ok) {
      const mm = r.out.trim().match(/[/:]([^/:]+(?:\/[^/:]+)+?)(?:\.git)?\s*$/);
      if (mm) repo = mm[1];
    }
  }
}
if (!repo || !pr) { emit({ ok: false, ask: true, reason: `cannot resolve ${!repo ? 'repository' : 'PR number'} from "${ref}"` }); process.exit(2); }

let me = null;
if (platform === 'github') {
  const auth = run('gh', ['auth', 'status', '--hostname', host]);
  if (!auth.ok) { emit({ ok: false, ask: true, reason: `gh not authenticated for ${host} — run gh auth login` }); process.exit(2); }
  const u = run('gh', ['api', 'user']);
  if (u.ok) { try { me = JSON.parse(u.out).login; } catch { me = u.out.trim() || null; } }
} else {
  const env = { GITLAB_HOST: host };
  const auth = run('glab', ['auth', 'status', '--hostname', host], { env });
  if (!auth.ok) { emit({ ok: false, ask: true, reason: `glab not authenticated for ${host} — run glab auth login --hostname ${host}` }); process.exit(2); }
  const u = runJson('glab', ['api', '--hostname', host, 'user'], { env });
  me = u.ok ? u.json.username : null;
}

emit({ ok: true, mode: 'public', platform, host, repo, pr, me,
  draftHint: platform === 'github' ? 'native' : 'probe-in-fetch-context' });
