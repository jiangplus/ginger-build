import ginger/secrets
import gleam/dict

pub fn parse_dotenv_basic_test() {
  let content = "FOO=bar\nBAZ=qux"
  assert secrets.parse_dotenv(content) == [#("FOO", "bar"), #("BAZ", "qux")]
}

pub fn parse_dotenv_skips_comments_and_blanks_test() {
  let content = "# a comment\n\nFOO=bar\n  # indented comment\nBAZ=qux\n"
  assert secrets.parse_dotenv(content) == [#("FOO", "bar"), #("BAZ", "qux")]
}

pub fn parse_dotenv_strips_quotes_test() {
  let content = "A=\"double\"\nB='single'\nC=plain"
  assert secrets.parse_dotenv(content)
    == [#("A", "double"), #("B", "single"), #("C", "plain")]
}

pub fn parse_dotenv_handles_export_and_equals_in_value_test() {
  let content = "export TOKEN=abc=def"
  assert secrets.parse_dotenv(content) == [#("TOKEN", "abc=def")]
}

pub fn match_exact_test() {
  assert secrets.match("RAILS_MASTER_KEY", "RAILS_MASTER_KEY") == True
  assert secrets.match("RAILS_MASTER_KEY", "OTHER") == False
}

pub fn match_prefix_glob_test() {
  assert secrets.match("STRIPE_*", "STRIPE_SECRET") == True
  assert secrets.match("STRIPE_*", "STRIPE_") == True
  assert secrets.match("STRIPE_*", "PAYPAL_KEY") == False
}

pub fn match_middle_glob_test() {
  assert secrets.match("A*Z", "ABCZ") == True
  assert secrets.match("A*Z", "AZ") == True
  assert secrets.match("A*Z", "ABC") == False
}

pub fn injected_selects_matching_keys_sorted_test() {
  let map =
    dict.from_list([
      #("RAILS_MASTER_KEY", "rk"),
      #("STRIPE_SECRET", "ss"),
      #("STRIPE_PUB", "sp"),
      #("HOME", "/root"),
    ])
  let result = secrets.injected(map, ["RAILS_MASTER_KEY", "STRIPE_*"])
  assert result
    == [
      #("RAILS_MASTER_KEY", "rk"),
      #("STRIPE_PUB", "sp"),
      #("STRIPE_SECRET", "ss"),
    ]
}

pub fn missing_keys_exact_test() {
  let map = dict.from_list([#("A", "1"), #("B", "")])
  // "A" present and non-empty → not missing; "B" empty → missing; "C" absent → missing
  assert secrets.missing_keys(map, ["A", "B", "C"]) == ["B", "C"]
}

pub fn missing_keys_ignores_globs_test() {
  let map = dict.from_list([])
  // globs are not validated (you can't tell if they'll match at runtime)
  assert secrets.missing_keys(map, ["STRIPE_*", "RAILS_MASTER_KEY"])
    == ["RAILS_MASTER_KEY"]
}

pub fn merge_overrides_test() {
  let base = dict.from_list([#("A", "1"), #("B", "2")])
  let merged = secrets.merge(base, [#("B", "override"), #("C", "3")])
  assert dict.get(merged, "A") == Ok("1")
  assert dict.get(merged, "B") == Ok("override")
  assert dict.get(merged, "C") == Ok("3")
}
