# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/integration_helpers"

class RegressionTest < Minitest::Test
  include IntegrationHelpers

  GENERATION_EXCLUSIONS = {
    "error_on_expect_mismatch.y" => "intentionally mismatched expected conflicts",
    "norule.y" => "intentionally missing grammar rules",
    "unterm.y" => "intentionally unterminated action"
  }.freeze
  RUBY_EXCLUSIONS = {
    "normal.y" => "actions contain intentionally invalid Ruby",
    "syntax.y" => "grammar exercises Racc syntax with non-Ruby actions"
  }.freeze
  PRE_18_EXCLUSIONS = {
    "group.y" => "group syntax requires Racc 1.8",
    "many.y" => "zero-or-more syntax requires Racc 1.8",
    "many1.y" => "one-or-more syntax requires Racc 1.8",
    "optional.y" => "optional syntax requires Racc 1.8"
  }.freeze
  SIGNATURE_EXCLUSIONS = {
    "machete.y" => "Could not find mixin: Matchers",
    "mailp.y" => "::TMail::Testp#parse has duplicated definitions",
    "mof.y" => "Could not find mixin: Helper",
    "namae.y" => "Could not find mixin: Singleton",
    "tp_plus.y" => "Could not find mixin: TPPlus::Nodes"
  }.freeze
  # Only supply the surrounding application types needed to reach the generated tables.
  NATIVE_CONTEXT = {
    "machete" => "module Matchers\nend\n",
    "mof" => "module Helper\nend\nmodule Scanner\nend\n",
    "namae" => "module Singleton\nend\n",
    "tp_plus" => "module TPPlus::Nodes\nend\n",
    "newsyn" => "class A\n  def self.e: () -> untyped\n  def self.f: () -> untyped\n  def self.d: () -> untyped\nend\n"
  }.freeze
  INLINE_EXCLUSIONS = {
    "chk" => "Top-level method definition is not supported",
    "echk" => "Top-level method definition is not supported",
    "opt" => "Top-level method definition is not supported",
    "mailp" => "Method definition with non-self receiver is not supported"
  }.freeze
  # These user AST classes inherit Object's zero-argument constructor, not Racc::Parser's.
  USER_CONSTRUCTOR_EXCLUSIONS = %w[cast intp].freeze

  def test_upstream_grammars
    corpus = ENV.fetch("RACC_CORPUS", File.join(ROOT, "tmp/racc"))
    grammars = Dir[File.join(corpus, "test/assets/*.y")].sort
    skip "Racc v1.8.1 corpus is absent; run ruby script/fetch-racc" if grammars.empty?
    unsupported = Gem::Version.new(Racc::VERSION) < Gem::Version.new("1.8") ? PRE_18_EXCLUSIONS : {}

    Dir.mktmpdir("racc-regression") do |dir|
      sources = {}
      targets = []
      grammars.each do |grammar|
        name = File.basename(grammar)
        next if GENERATION_EXCLUSIONS.key?(name) || RUBY_EXCLUSIONS.key?(name) || unsupported.key?(name)

        id = File.basename(grammar, ".y")
        project = File.join(dir, id)
        FileUtils.mkdir_p(project)
        out, err, status = gem_command("racc", "racc", "-o", File.join(project, "parser.rb"), grammar)
        assert status.success?, "#{name}: #{out}#{err}"
        generated = File.read(File.join(project, "parser.rb"))
        source = RaccRbsInline.annotate(generated)
        assert_equal source, RaccRbsInline.annotate(generated, grammar: File.read(grammar), grammar_filename: grammar), name
        write_type_project(project, source)
        sources["#{id}/parser.rb"] = source
        out, err, status = command(RbConfig.ruby, "-c", "parser.rb", chdir: project)
        assert status.success?, "#{name}: #{out}#{err}"
        assert_equal source, RaccRbsInline.annotate(source), name

        out, err, status = gem_command("rbs-inline", "rbs-inline", "parser.rb", chdir: project)
        assert status.success?, "#{name}: #{err}"
        File.write(File.join(project, "sig/generated.rbs"), out)
        out, err, status = gem_command("rbs", "rbs", "-I", "sig", "validate", chdir: project)
        if SIGNATURE_EXCLUSIONS.key?(name)
          assert_includes "#{out}#{err}", SIGNATURE_EXCLUSIONS.fetch(name), name
        else
          assert status.success?, "#{name}: #{out}#{err}"
        end
        FileUtils.rm(File.join(project, "sig/generated.rbs"))
        if NATIVE_CONTEXT.key?(id)
          File.write(File.join(project, "sig/context.rbs"), NATIVE_CONTEXT.fetch(id))
        end

        targets << <<~RUBY
          target #{id.to_sym.inspect} do
            unreferenced!
            check #{"#{id}/parser.rb".inspect}, inline: true
            signature #{"#{id}/sig".inspect}
            configure_code_diagnostics(Steep::Diagnostic::Ruby.strict)
          end
        RUBY
      end
      assert_equal 53 - unsupported.length, sources.length, "Update the explicit exclusion lists if the pinned upstream corpus changes"
      File.write(File.join(dir, "Steepfile"), targets.join("\n"))
      diagnostics = steep_diagnostics(dir)
      failures = diagnostics.flat_map do |entry|
        file = entry.fetch("file")
        source = sources[file]
        if source
          id = file.split("/").first
          generated_diagnostics(source, entry.fetch("diagnostics")).reject do |diagnostic|
            line = source.lines.fetch(diagnostic.dig("range", "start", "line") - 1)
            (diagnostic["code"] == "RBS::InlineDiagnostic" && INLINE_EXCLUSIONS[id] == diagnostic["message"]) ||
              (USER_CONSTRUCTOR_EXCLUSIONS.include?(id) && diagnostic["code"] == "Ruby::MethodParameterMismatch" &&
                line.match?(/^\s*def initialize\b/))
          end.map { |d| [file, d] }
        else
          entry.fetch("diagnostics").map { |d| [file, d] }
        end
      end
      assert_empty failures, failures.inspect
    end
  end
end
