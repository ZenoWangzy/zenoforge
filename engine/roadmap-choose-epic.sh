roadmap_choose_epic() {
  local tree="$1" issue_json="$2" source_issue="${3:-}" flat
  flat="$(roadmap_flatten "$tree")" || return 1
  jq -ce --slurpfile flat_s <(printf '%s' "$flat") --arg source "$source_issue" '($flat_s[0]) as $flat |
    def topic_words($s):
      [$s | ascii_downcase | scan("[a-z0-9]{2,}")
       | select(. as $word | (["a","an","and","are","as","at","be","by","for","from","in","into","is","it","of","on","or","the","to","via","with","new","issue","ticket","request","task","follow","up","roadmap","map"] | index($word)) == null)];
    def chinese_bigrams($s):
      ($s | explode) as $chars
      | [range(0; (($chars | length) - 1)) as $i
         | select($chars[$i] >= 19968 and $chars[$i] <= 40959
             and $chars[$i + 1] >= 19968 and $chars[$i + 1] <= 40959)
         | [$chars[$i], $chars[$i + 1]] | implode];
    def issue_labels: [(.labels // [])[] | if type == "string" then . else .name // "" end];
    def score($text_words; $text_bigrams; $title):
      ([topic_words($title)[] as $word | select($text_words | index($word)) | $word] | unique | length) * 3
      + ([chinese_bigrams($title)[] as $pair | select($text_bigrams | index($pair)) | $pair] | unique | length);
    . as $issue
    | ($flat | map({key:(.number|tostring),value:.}) | from_entries) as $nodes
    | [$flat[] | select(.depth == 2 and (.labels | index("roadmap-epic") != null) and .title != "待归类")] as $epics
    | ($issue | issue_labels) as $labels
    | (if ($labels | index("pipeline-system")) != null then
         [$epics[] | select(.theme_milestone == "开发流水线与运行稳定")]
       else $epics end) as $candidate_epics
    | (if ($labels | index("pipeline-system")) != null
         and (($issue.title // "") | ascii_downcase | startswith("pipeline health:")) then
         [$candidate_epics[] | select(.title == "自动派发与规则校验持续可靠")][0]
       else null end) as $pipeline_health_epic
    | (if ($source | test("^[1-9][0-9]*$")) then $nodes[$source] else null end) as $source_node
    | (if $source_node != null then $nodes[($source_node.parent|tostring)] else null end) as $inherited
    | (($issue.title // "") as $text
       | topic_words($text) as $text_words
       | chinese_bigrams($text) as $text_bigrams
       | (if $pipeline_health_epic != null then $pipeline_health_epic
          elif $inherited != null and ($inherited.labels | index("roadmap-epic") != null)
            and (($labels | index("pipeline-system")) != null
              or score($text_words;$text_bigrams;$inherited.title) >= 2)
            and (($labels | index("pipeline-system")) == null
              or $inherited.theme_milestone == "开发流水线与运行稳定") then $inherited
          else
            [$candidate_epics[] | . + {score:score($text_words;$text_bigrams;.title)} | select(.score >= 2)]
            | sort_by([-.score,.order]) | .[0]
          end) as $preferred
       | if $preferred == null then {epic:null,title:null,milestone:null}
         else
           (if (($preferred.children_total // (($preferred.children // []) | length)) < 100) then $preferred
            else
              [$candidate_epics[]
               | select(.theme == $preferred.theme)
               | select((.children_total // ((.children // []) | length)) < 100)
               | . + {score:score($text_words;$text_bigrams;.title)}
               | select(.score >= 2)]
              | sort_by([-.score,.order]) | .[0]
            end) as $selected
           | if $selected == null then {epic:null,title:null,milestone:null}
             else {epic:$selected.number,title:$selected.title,milestone:$selected.theme_milestone} end
         end)
  ' <<< "$issue_json"
}
