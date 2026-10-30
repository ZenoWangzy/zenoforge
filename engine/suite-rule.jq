# PR CI and landings run incident guards without rg on PATH (PR 2212, landing 238).
# check-rulings.sh uses this predicate so an incident guard and
# its folded registry form are refused by the same rule, not two copies of one regex.
def rg_invocation:
  test("(^|[;&|({[:space:]])rg[[:space:]]+-");

def suite_runner_regex:
  "^(?:(?:env\\s+[^;&|()]+?|[A-Za-z_][A-Za-z0-9_]*=[^\\s;&|()]+)\\s+)*(bash|sh|node|vitest|jest|pnpm|npx)(\\s+[^\\s;&|()]+)*\\s";

def suite_path_regex:
  "[^\\s;&|()\"']*(?:\\.test\\.(?:sh|cjs|mjs|ts|js)|/test-[^\\s/]+\\.sh)";

def valid_incident_test_file:
  type == "string" and
  (startswith("${REPO_DIR}/engine/") or startswith("engine/") or . == "scripts/branch-delivery-preflight.test.mjs") and
  (test("\\.test\\.(sh|mjs|ts|js)$") or test("/test-[^/]+\\.sh$"));

def shell_suite_paths:
  [splits("[;&|()]+")
   | gsub("^\\s+|\\s+$"; "") as $segment
   | select($segment != "")
   | select(($segment | test("^(grep|rg|cat)(\\s|$)")) | not)
   | select($segment | test(suite_runner_regex))
   | $segment | scan(suite_path_regex) | select((split("/") | last) != "test-env.sh")];

def command_suite_paths($command):
  if ($command | type) != "array" then []
  else
    $command as $argv
    | if (($argv | length) >= 3)
      and (($argv[0] | split("/") | last) == "bash" or ($argv[0] | split("/") | last) == "sh")
      and (["-c", "-lc", "-ec", "-euc", "-ce", "-lec", "-elc"] | index($argv[1]) != null)
      then ($argv[2] | shell_suite_paths)
      else ($argv | join(" ") | shell_suite_paths)
      end
  end;
