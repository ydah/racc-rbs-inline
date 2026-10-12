# frozen_string_literal: true

require "racc"

module IntegrationHelpers
  ROOT = File.expand_path("../..", __dir__)
  FIXTURES = File.join(ROOT, "test/fixtures")
  VARIANTS = {
    "default" => [], "no_line_convert" => ["-l"], "embedded" => ["-E"],
    "frozen" => ["-F"], "executable" => ["-E", "-F", "--executable=/usr/bin/ruby"],
    "no_result_var" => [], "all_actions" => ["-a"], "debug" => ["-t"],
    "line_convert_all" => ["--line-convert-all"],
    "superclass" => ["--superclass=CustomParser"], "nested" => [],
    "convert" => [], "japanese" => []
  }.freeze

  def command(*args, chdir: ROOT)
    Open3.capture3(*args, chdir: chdir)
  end

  def gem_command(gem, executable, *args, chdir: ROOT)
    command(RbConfig.ruby, Gem.bin_path(gem, executable), *args, chdir: chdir)
  end

  def grammar_for(variant)
    source = File.read(File.join(FIXTURES, "sum.y"))
    case variant
    when "no_result_var"
      source.sub!("rule", "options no_result_var\nrule")
      source.gsub!("result = ", "")
    when "nested"
      source.sub!("class SumParser", "class A::B::SumParser")
    when "convert"
      source.sub!("rule", "convert\n  NUMBER 'Integer'\nend\nrule")
    when "japanese"
      source.sub!("# Header preserved by annotation.", '# 日本語のコメントと文字列を保存する。')
      source.sub!("    @tokens = tokens", '    label = "合計"' + "\n    @tokens = tokens")
    when "superclass"
      source.sub!("# Header preserved by annotation.", "require 'racc/parser'\nclass CustomParser < Racc::Parser; end")
    end
    source
  end

  def generate_variant(dir, variant)
    File.write(File.join(dir, "sum.y"), grammar_for(variant))
    options = VARIANTS.fetch(variant)
    options = options - ["-F"] if legacy_racc?
    out, err, status = gem_command("racc", "racc", *options, "-o", "parser.rb", "sum.y", chdir: dir)
    assert status.success?, "#{variant}: #{out}#{err}"
    File.read(File.join(dir, "parser.rb"))
  end

  def legacy_racc?
    Gem::Version.new(Racc::VERSION) < Gem::Version.new("1.7")
  end

  def expected_golden(variant)
    expected = File.read(File.join(FIXTURES, "golden", "#{variant}.rb"))
    return expected unless legacy_racc?

    # Racc 1.6 predates frozen output, Ractor tables, and the grammar filename notice.
    expected.sub('# from Racc grammar file "sum.y".', '# from Racc grammar file "".')
      .sub("# frozen_string_literal: true\n", "")
      .gsub(/^Ractor\.make_shareable\(Racc_(?:arg|token_to_s_table)\) if defined\?\(Ractor\)\n/, "")
  end

  def normalize_golden(source)
    source.gsub(/Racc version \d+\.\d+\.\d+/, "Racc version VERSION")
      .gsub(/Racc \d+\.\d+\.\d+/, "Racc VERSION")
      .sub(/\A#![^\n]+/, "#!/usr/bin/env ruby")
      .gsub(/(\.\.\.end [^\n']+\/module_eval\.\.\.)[0-9a-f]+/, '\\1ID')
      .sub(/###### racc\/parser\.rb begin\n.*?###### racc\/parser\.rb end/m, "# Embedded runtime (checked byte-for-byte separately).")
  end

  def write_type_project(dir, source, inline: true)
    FileUtils.mkdir_p(File.join(dir, "sig"))
    FileUtils.cp(File.join(ROOT, "data/racc/parser.rbs"), File.join(dir, "sig/racc.rbs"))
    File.write(File.join(dir, "parser.rb"), source)
    File.write(File.join(dir, "Steepfile"), <<~RUBY)
      target :parser do
        check "parser.rb", inline: #{inline}
        signature "sig"
        configure_code_diagnostics(Steep::Diagnostic::Ruby.strict)
      end
    RUBY
  end

  def steep_diagnostics(dir)
    out, err, status = gem_command("steep", "steep", "check", "--jobs=1", "--format=github", chdir: dir)
    diagnostics = out.lines.filter_map do |line|
      match = line.match(/^::(error|warning|notice) file=(.*?),line=(\d+),.*?::\[([^\]]+)\] (.*)/)
      next unless match
      { "file" => match[2], "severity" => match[1].upcase, "code" => match[4],
        "message" => match[5], "range" => { "start" => { "line" => match[3].to_i } } }
    end
    assert status.success? || (status.exitstatus == 1 && !diagnostics.empty?), "Steep failed: #{out}#{err}"
    diagnostics.group_by { |d| d.fetch("file") }.map { |file, ds| { "file" => file, "diagnostics" => ds } }
  end

  def generated_diagnostics(source, diagnostics)
    first = source.lines.index { |line| line.include?("State transition tables begin") }
    last = source.lines.index { |line| line.include?("State transition tables end") }
    diagnostics.select do |diagnostic|
      code = diagnostic.fetch("code")
      line = diagnostic.dig("range", "start", "line")
      (first && last && (first + 1..last + 1).cover?(line)) ||
        code.start_with?("RBS::") ||
        %w[Ruby::FalseAssertion Ruby::MethodParameterMismatch].include?(code) ||
        code.match?(/Unused.*Annotation|Annotation.*Unused/)
    end
  end
end
