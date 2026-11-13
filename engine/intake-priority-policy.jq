# Shared policy functions for intake labels and scheduler dispatch ordering.
def intake_labels:
  (.labels // [] | map(if type == "string" then . else .name // "" end));

def intake_issue_number:
  .number // .issue;

def intake_founder_ask($item; $config):
  ((($config.founder_issues // []) | index($item | intake_issue_number)) != null)
  or ((($item | intake_labels) | index("founder-test")) != null);

def intake_off_market($item; $config):
  ((($config.off_market_issues // []) | index($item | intake_issue_number)) != null)
  or (
    (($item.title // "") + " " + (($item | intake_labels) | join(" ")) | ascii_downcase) as $haystack
    | any(($config.off_market_terms // [])[]; . as $term | $haystack | contains($term | ascii_downcase))
  );

def intake_hotfix_incident($item):
  (
    (($item | intake_labels) | map(ascii_downcase)
      | any(.[]; . == "hotfix" or . == "incident" or . == "production-anomaly" or . == "prod-anomaly"))
    or (($item.title // "") | startswith("Incident: "))
    or (($item.title // "") | test("(?i)(\\[\\s*hotfix\\s*\\]|\\[\\s*hot-fix\\s*\\]|\\[\\s*热修\\s*\\]|【\\s*热修\\s*】|（[^）]*热修）)"))
  );

def intake_bug($item):
  (($item | intake_labels) | index("bug")) != null;

def intake_fruit_feature($item):
  (($item | intake_labels) | index("enhancement")) != null;

def intake_priority_overlay($issue; $decision; $config):
  ($config.labels) as $labels_config
  | intake_founder_ask($issue; $config) as $founder
  | intake_off_market($issue; $config) as $off_market
  | intake_hotfix_incident($issue) as $hotfix_incident
  | intake_bug($issue) as $bug
  | intake_fruit_feature($issue) as $fruit_feature
  | (if $hotfix_incident then $labels_config.top
     elif $off_market and ($founder | not) then $labels_config.low
     elif $bug then $labels_config.high
     elif $off_market then $labels_config.low
     elif $fruit_feature then $labels_config.normal
     else $decision.priority end) as $classified_priority
  | (if $founder then
       (if $decision.priority == $labels_config.high or $decision.priority == $labels_config.top
           or $classified_priority == $labels_config.top
        then $labels_config.top else $labels_config.high end)
     else $classified_priority end) as $priority
  | (if $founder then "founder-ask"
     elif $hotfix_incident then "hotfix-incident"
     elif $off_market then "off-market"
     elif $bug then "bug"
     elif $fruit_feature then "fruit-feature"
     else null end) as $overlay
  | $decision + {priority:$priority,overlay:$overlay};

def intake_dispatch_tier($unit; $config):
  if intake_hotfix_incident($unit) then 0
  elif intake_off_market($unit; $config) and (intake_founder_ask($unit; $config) | not) then 3
  elif intake_bug($unit) then 1
  else 2
  end;
