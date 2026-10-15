<h1 align="center">racc-rbs-inline</h1>

<p align="center">
  <strong>Inline RBS annotations and semantic value types for Racc-generated Ruby parsers.</strong>
</p>

<p align="center">
  <a href="https://rubygems.org/gems/racc-rbs-inline"><img src="https://img.shields.io/gem/v/racc-rbs-inline?color=319e8c" alt="Gem version"></a>
  <a href="https://rubygems.org/gems/racc-rbs-inline"><img src="https://img.shields.io/gem/required-ruby-version/racc-rbs-inline" alt="Required Ruby version"></a>
  <a href="https://github.com/ydah/racc-rbs-inline/actions/workflows/main.yml"><img src="https://github.com/ydah/racc-rbs-inline/actions/workflows/main.yml/badge.svg" alt="Ruby and Racc tests"></a>
  <a href="https://github.com/ydah/racc-rbs-inline/actions/workflows/lrama.yml"><img src="https://github.com/ydah/racc-rbs-inline/actions/workflows/lrama.yml/badge.svg" alt="Lrama acceptance"></a>
  <a href="LICENSE.txt"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT license"></a>
</p>

<p align="center">
  <a href="#features">Features</a> ·
  <a href="#installation">Installation</a> ·
  <a href="#quick-start">Quick start</a> ·
  <a href="#usage">Usage</a> ·
  <a href="#type-checking">Type checking</a> ·
  <a href="#development">Development</a>
</p>

---

Add one command after Racc to make generated parser tables and reduction methods
available to **rbs-inline 0.14** and **Steep 2.0's native inline support**.
Annotations are comments, so generated parsers keep their existing runtime dependencies.

## Features

- Annotate generated tables, constants, and reduction methods without modifying Racc.
- Declare semantic value types in grammar comments to check action arguments and results.
- Generate and annotate in one command, or use a Rake file task.
- Refresh annotations safely, with idempotence and grammar/table mismatch checks.
- Use either native inline checking or extracted RBS signatures.

## Installation

Add this development dependency to your Gemfile:

```ruby
group :development do
  gem "racc-rbs-inline", "~> 0.1.0"
  gem "racc", "1.8.1"
  gem "rbs-inline", "0.14.0" # only needed for the extraction workflow
  gem "steep", "2.0.0"
end
```

Then run `bundle install`.

### Requirements

| Dependency | Supported versions |
| --- | --- |
| Ruby | 3.2+ |
| Prism | 1.0+ |
| Racc | 1.6.2 to below 2.0 |
| RBS | 4.1 to below 5.0 |
| Type checker | Steep 2.0; rbs-inline 0.14 for signature extraction |

## Quick start

Add one command after your existing Racc invocation:

```sh
bundle exec racc -o lib/parser.rb parser.y
bundle exec racc-rbs-inline annotate lib/parser.rb
```

Or generate and annotate together:

```sh
bundle exec racc-rbs-inline generate parser.y -o lib/parser.rb -- --embedded --frozen
```

Continue with [type checking](#type-checking) to install the runtime signatures
and choose a Steep workflow. Example grammars are available in
[test/fixtures/sum.y](test/fixtures/sum.y) and
[test/fixtures/typed_calc.y](test/fixtures/typed_calc.y).

## Usage

`-o` is required. Arguments after `--` are passed to Racc, which runs as a separate
process. Racc's exit status is preserved if generation fails. For executable
output with Racc 1.8.1, specify a path such as `--executable=/usr/bin/ruby`;
Racc itself rejects an omitted executable path on some Ruby versions.

```sh
# Annotate several files in place.
bundle exec racc-rbs-inline annotate lib/parser.rb lib/other_parser.rb

# Print the transformed source, leaving files alone.
bundle exec racc-rbs-inline annotate --stdout lib/parser.rb

# Add semantic value types declared in the grammar.
bundle exec racc-rbs-inline annotate lib/parser.rb --grammar parser.y

# List files needing annotation; exit 1 if any need changes, otherwise 0.
bundle exec racc-rbs-inline annotate --check lib/parser.rb

# Copy runtime signatures when not using rbs collection.
# Defaults to sig/racc/parser.rbs.
bundle exec racc-rbs-inline sig --output sig/racc

bundle exec racc-rbs-inline --help
bundle exec racc-rbs-inline --version
```

Invalid Ruby, including invalid Ruby exposed when action wrappers are removed,
is rejected before writing the annotated file. `annotate` validates every input
before writing any of them. Repeating annotation leaves the file unchanged.

### Ruby API

The library API returns source text without performing file I/O:

```ruby
require "racc_rbs_inline"

annotated_source = RaccRbsInline.annotate(source)
RaccRbsInline.annotated?(annotated_source) # => true

# Supply grammar text to add or refresh semantic value types.
annotated_source = RaccRbsInline.annotate(source,
  grammar: File.read("parser.y"), grammar_filename: "parser.y")
```

`annotated?` detects the `# rbs_inline: enabled` comment. Without a grammar,
files already carrying that marker are left untouched. Supplying a grammar
validates the generated tables and refreshes reduction signatures, including
files that already have generic annotations.

## Semantic value types

Declare terminal and nonterminal types in grammar comments:

```ruby
class TypedCalc
  # @racc-type NUMBER exp target : Integer
  # @racc-type '+' '(' ')' : String
rule
  target: exp { result = val[0] }
  exp: NUMBER { result = val[0] }
     | exp '+' NUMBER { result = val[0] + val[2] }
     | '(' exp ')' { result = val[1] }
end
```

`generate` and the Rake task read these declarations automatically. For an
existing generated parser, pass `annotate --grammar parser.y`. Use the same
Racc version that generated the parser: mismatched rule tables are rejected
before writing. Invalid RBS types, unknown symbols, and conflicting declarations
are also errors. Semantic type processing requires quoted grammar symbols to
be literal strings without Ruby interpolation.

Each reduction receives a tuple of the right-hand-side types and returns the
left-hand-side type. Undeclared symbols stay `untyped`. The initial `result`
parameter includes both the first right-hand-side type (or `nil` for an empty
rule) and the left-hand-side type. `no_result_var` grammars receive two
parameters instead. Racc 1.8's `?`, `*`, and `+` symbols become optional or array
types; groups become `Array[untyped]`. Generated helper reductions and
`_reduce_none` retain generic signatures.

With the declarations above, returning `val[0]` from the parenthesized rule is
reported as a `String`/`Integer` mismatch by both checking workflows. A runnable
example, including token handling, is in
[test/fixtures/typed_calc.y](test/fixtures/typed_calc.y).

## Rake integration

```ruby
require "racc_rbs_inline/rake_task"

RaccRbsInline::RakeTask.new(:parser) do |task|
  task.grammar = "parser.y"
  task.output = "lib/parser.rb"
  task.options = ["--embedded", "--frozen"]
end
```

`bundle exec rake parser` regenerates and annotates the output when the grammar
is newer or the output is absent. The output is also available as a file task.

## Type checking

For Racc 1.8, the `Racc::Parser` runtime signatures are available from
[gem_rbs_collection](https://github.com/ruby/gem_rbs_collection/tree/main/gems/racc/1.8).
Initialize collection configuration once:

```sh
bundle exec rbs collection init
```

For v0.1.0, exclude build and type-checker signatures when checking your
application's generated parser. Add these entries to `gems:` in
`rbs_collection.yaml`:

```yaml
gems:
  - name: racc-rbs-inline
    ignore: true
  - name: rbs
    ignore: true
  - name: rbs-inline
    ignore: true
  - name: steep
    ignore: true
```

Then install the signatures:

```sh
bundle exec rbs collection install
```

If your collection lock predates Racc's registration, run
`bundle exec rbs collection update`. Remove any copied `sig/racc` directory
when switching to collection signatures to avoid duplicate declarations.

For Racc 1.6 / 1.7, or projects without collection, copy the bundled runtime
signatures instead:

```sh
bundle exec racc-rbs-inline sig
```

These signatures live in `data/racc` inside the gem and are loaded only when
copied into your signature directory. The `sig` command remains supported.

### Native inline support (Steep 2.0)

```ruby
# Steepfile
target :lib do
  signature "sig"
  check "lib", inline: true
end
```

```sh
bundle exec steep check
```

### Extract signatures with rbs-inline

```ruby
# Steepfile
target :lib do
  signature "sig"
  check "lib"
end
```

```sh
bundle exec rbs-inline --output=sig/generated lib
bundle exec steep check
```

Choose one workflow; do not load extracted declarations while also enabling
native inline checking for the same parser.

A complete small grammar is in [test/fixtures/sum.y](test/fixtures/sum.y).
After setting up collection configuration above, copy that grammar to
`parser.y` in a project with the Gemfile above:

```sh
mkdir -p lib
bundle exec racc-rbs-inline generate parser.y -o lib/parser.rb
bundle exec rbs collection install
# Save either Steepfile above, then run that workflow's commands.
```

The integration tests exercise this grammar through both workflows, including
strict diagnostics. To enable strict diagnostics in your own target, add
`configure_code_diagnostics(Steep::Diagnostic::Ruby.strict)`.

## How it works

The annotator locates classes whose bodies assign `Racc_arg`. It unwraps their
heredoc `module_eval` calls, then annotates ten tables, three constants, and all
`_reduce_N` / `_reduce_none` methods. Reduction arguments and results use
`untyped` unless grammar declarations supply semantic value types.

User-written actions, `header`, `inner`, and `footer` code remain your
responsibility to type. Existing annotations in `inner` become visible after
unwrapping. Separate instance variable annotations from method definitions
with a blank line:

```ruby
---- inner
  # @rbs @tokens: Array[Array[untyped]]

  #: (Array[Array[untyped]]) -> void
  def initialize(tokens)
    @tokens = tokens
  end
```

**Backtrace locations change:** unwrapping `module_eval` means exceptions point
to the generated `.rb` file instead of the grammar's `.y` lines, as with Racc's
`--no-line-convert` option. Code relying on `__FILE__`, `__LINE__`, or lexical
scope inside those wrappers should account for the same change.

The implementation preserves other source bytes, including embedded runtime
code, header/footer wrappers, encoding declarations, and line endings.

## Development

```sh
bundle install
bundle exec rbs collection install
ruby script/fetch-racc
bundle exec rake
```

`rake test` runs unit tests, 13 golden/behavior variants, both type-checking
workflows, semantic value checks, deliberately corrupt table tests, and the
upstream Racc corpus.

<details>
<summary>Regression coverage and compatibility</summary>

The corpus is fetched from the pinned `v1.8.1` tag into ignored `tmp/racc` and is
not redistributed. Set `RACC_CORPUS` to use another local copy. Without the
corpus, that regression test reports a skip; CI always fetches it.

The 58 upstream grammars include three intentional generator errors and two
with invalid Ruby actions. All other 53 are checked separately to avoid class
name collisions. User-code signature failures are documented in
[test/regression_test.rb](test/regression_test.rb); generated table diagnostics
must be absent. The embedded runtime is checked byte-for-byte while golden
files normalize its representation, version banners, random delimiter IDs,
and executable paths.

`rake typecheck` regenerates this gem's own signatures and checks them with
Steep. CI covers Ruby 3.2, 3.3, 3.4, and 4.0, with Racc 1.8.1 as the baseline
and additional Racc 1.6.2 / 1.7.3 compatibility jobs.
Racc 1.6.2 does not support `--frozen`; that variant is skipped there.
Racc 1.6.2 and 1.7.3 cannot generate the four upstream grammars using Racc 1.8's
group/optional/repetition syntax, so their corpus checks cover the remaining 49.

The separate Lrama acceptance job checks the pinned upstream parser before and
after generation with `--embedded --frozen` (79 examples each), then checks
generated annotations with strict Steep diagnostics. Run it locally with
`bundle exec ruby script/test-lrama`; it fetches Lrama into ignored `tmp/lrama`
and writes reports to `tmp/lrama-acceptance`. It restores the original parser
after the check and requires a clean checkout at the pinned revision.
Application type errors remain in the report; two unrelated profiler signatures
using unsupported `void` unions are excluded from the temporary checking project.

</details>

Repository checks also cover GitHub Actions syntax, YAML, spelling, and workflow
security. Dependabot checks Bundler dependencies and GitHub Actions weekly.

### Releasing

Update `RaccRbsInline::VERSION`, run `bundle exec rake`, and commit the version
and any updated `rbs_collection.lock.yaml` before pushing a matching `vX.Y.Z` tag.
The [release workflow](.github/workflows/release.yml) runs the checks, publishes
through RubyGems Trusted Publishing, and creates a GitHub Release with the Gem
attached and generated release notes.

The RubyGems Trusted Publisher must point to `ydah/racc-rbs-inline`, workflow
`release.yml`, with no environment name.

## Contributing

[Bug reports](https://github.com/ydah/racc-rbs-inline/issues) and pull requests
are welcome. Include a minimal grammar, generation flags, and the Ruby, Racc,
RBS, and Steep versions when reporting a problem.

## License

Released under the [MIT License](LICENSE.txt).
