'use strict';
// Page ownership records for shared-CDP checks (ruling close-browser-pages-after-use).
// A check that opens a page in the leased shared browser registers the target id
// here immediately after opening it; cdp-browser-lease.sh then closes registered
// pages when the lease ends, whichever way the check ended — success, failure,
// cancel, or crash before its own cleanup ran. Only a page with a confirmed
// follow-up task is marked retained, an explicit ownership transfer: it stays
// recorded and is never reaped until its next owner closes or releases it.

const fs = require('node:fs');

const TARGET_ID_PATTERN = /^[0-9a-f]{32}$/i;

function leaseTargetsFile() {
  return process.env.ZF_WEB_SESSION_LEASE_TARGETS_FILE || '';
}

// Register a page this check opened. No-op outside a lease (own-profile Chrome
// runs die with their browser) and for non-page target ids. A record write that
// fails is skipped: the check's own in-process cleanup still closes the page.
function registerCreatedPage(targetId) {
  const file = leaseTargetsFile();
  if (!file || !TARGET_ID_PATTERN.test(targetId)) return;
  try { fs.appendFileSync(file, `${targetId}\n`); } catch {}
}

// A later lease may adopt a page retained by an earlier owner. Both forms
// remain explicit ownership records; an unrecorded target is never ours.
function isRegisteredPage(targetId) {
  const file = leaseTargetsFile();
  if (!file || !TARGET_ID_PATTERN.test(targetId)) return false;
  try {
    const lines = fs.readFileSync(file, 'utf8').split('\n');
    return lines.includes(targetId) || lines.includes(`retained:${targetId}`);
  } catch { return false; }
}

function setRetainedPage(targetId, retained) {
  const file = leaseTargetsFile();
  if (!file || !TARGET_ID_PATTERN.test(targetId)) return;
  try {
    const lines = fs.readFileSync(file, 'utf8').split('\n').filter(Boolean);
    const known = lines.includes(targetId) || lines.includes(`retained:${targetId}`);
    const next = lines.filter((line) => line !== targetId && line !== `retained:${targetId}`);
    if (retained && known) next.push(`retained:${targetId}`);
    fs.writeFileSync(file, `${next.join('\n')}\n`);
  } catch {}
}

// Explicit ownership transfer: the page has a confirmed follow-up task under a
// later lease, so this lease must not close it.
function retainCreatedPage(targetId) { setRetainedPage(targetId, true); }

// Drop the record once the page is confirmed closed. A close that failed keeps
// the record so the lease reaps the still-open page.
function releaseCreatedPage(targetId) { setRetainedPage(targetId, false); }

module.exports = { registerCreatedPage, isRegisteredPage, retainCreatedPage, releaseCreatedPage };
