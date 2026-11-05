// Blinding rules for what a stage worker sees, adapted from the poteto-mode eval playbook
// (engine/vendor/pstack/skills/poteto-mode/playbooks/eval.md). The worker must get its ordinary
// prompt and nothing that says it is measured. Adaptation: `test`, `compare` and `candidate` stay
// allowed because the shipped pipeline prompts use them for real work; only words that reveal
// the measurement itself are banned. Directory names, other runs and the hidden checks follow the
// same rule (README, "Blinding").
export const META_WORDS = /\b(eval\w*|judg\w*|experiment\w*|rubric\w*|scor(?:e|es|ed|ing)|benchmark\w*|arena|frozen|historical|grader)\b/i;
export const blindingLeaks = (text) => [...new Set(String(text).match(new RegExp(META_WORDS.source, 'gi')) ?? [])];
