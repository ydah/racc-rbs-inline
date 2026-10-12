# frozen_string_literal: true

require_relative "test_helper"
require "racc_rbs_inline/cli"
require "minitest/mock"
require "stringio"

class CLITest < Minitest::Test
  SOURCE = "class Example\n  Racc_arg = []\nend\n"
  GRAMMAR = "class Example\nrule\n  target: NUMBER { result = val[0] }\nend\n"

  def setup
    @dir = Dir.mktmpdir("racc-rbs-inline-cli-")
    @out = StringIO.new
    @err = StringIO.new
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def run_cli(*args)
    RaccRbsInline::CLI.run(args, out: @out, err: @err)
  end

  def write(name, source)
    path = File.join(@dir, name)
    File.binwrite(path, source)
    path
  end

  def test_annotate_and_check
    path = write("parser.rb", SOURCE)
    File.chmod(0o755, path)
    assert_equal 1, run_cli("annotate", "--check", path)
    assert_equal "#{path}\n", @out.string
    assert_equal SOURCE, File.binread(path)
    assert_equal 0, run_cli("annotate", path)
    assert_equal RaccRbsInline.annotate(SOURCE), File.binread(path)
    assert_equal 0o755, File.stat(path).mode & 0o777
    @out.truncate(0)
    @out.rewind
    assert_equal 0, run_cli("annotate", "--check", path)
    assert_empty @out.string
  end

  def test_stdout_does_not_write
    path = write("parser.rb", SOURCE)
    assert_equal 0, run_cli("annotate", path, "--stdout")
    assert_equal RaccRbsInline.annotate(SOURCE), @out.string
    assert_equal SOURCE, File.binread(path)
  end

  def test_annotation_errors_leave_all_inputs_untouched
    good = write("good.rb", SOURCE)
    bad_source = "class Broken\n"
    bad = write("bad.rb", bad_source)
    assert_equal 1, run_cli("annotate", good, bad)
    assert_equal SOURCE, File.binread(good)
    assert_equal bad_source, File.binread(bad)
    assert_includes @err.string, bad
  end

  def test_invalid_arguments_and_missing_inputs
    [[], ["unknown"], ["annotate"], ["annotate", "--check", "--stdout", "x.rb"],
     ["annotate", File.join(@dir, "missing.rb")], ["generate", "grammar.y"],
     ["generate", "-o", "out.rb"], ["sig", "extra"]].each do |args|
      refute_equal 0, run_cli(*args), args.inspect
    end
  end

  def test_generate_matches_racc_followed_by_annotation
    grammar = write("parser with spaces.y", GRAMMAR)
    raw = File.join(@dir, "raw.rb")
    output = File.join(@dir, "generated parser.rb")
    options = ["--embedded", "--executable=#{RbConfig.ruby}"]
    options << "--frozen" if Gem::Specification.find_by_name("racc").version >= Gem::Version.new("1.7")
    _, stderr, status = Open3.capture3(RbConfig.ruby, Gem.bin_path("racc", "racc"),
                                      grammar, "-o", raw, *options)
    assert status.success?, stderr
    assert_equal 0, run_cli("generate", grammar, "-o", output, "--", *options), @err.string
    assert_equal RaccRbsInline.annotate(File.binread(raw)), File.binread(output)
    assert File.executable?(output)
  end

  def test_failed_generation_keeps_existing_output_and_racc_exit_status
    grammar = write("bad.y", "invalid grammar\n")
    output = write("parser.rb", "existing parser\n")
    _, _, status = Open3.capture3(RbConfig.ruby, Gem.bin_path("racc", "racc"), grammar, "-o", File.join(@dir, "raw.rb"))
    refute status.success?
    assert_equal status.exitstatus, run_cli("generate", grammar, "-o", output)
    assert_equal "existing parser\n", File.binread(output)
    refute_empty @err.string
  end

  def test_generate_falls_back_to_racc_on_path
    grammar = write("parser.y", GRAMMAR)
    output = File.join(@dir, "parser.rb")
    missing_gem = ->(*) { raise Gem::GemNotFoundException, "racc not found" }
    Gem.stub(:bin_path, missing_gem) do
      assert_equal 0, run_cli("generate", grammar, "-o", output), @err.string
    end
    assert RaccRbsInline.annotated?(File.binread(output))
  end

  def test_generate_preserves_existing_modes_and_honors_executable_option
    grammar = write("parser.y", GRAMMAR)
    output = write("parser.rb", "existing parser\n")
    [0o600, 0o755].each do |mode|
      File.chmod(mode, output)
      assert_equal 0, run_cli("generate", grammar, "-o", output), @err.string
      assert_equal mode, File.stat(output).mode & 0o777
    end
    File.chmod(0o600, output)
    assert_equal 0, run_cli("generate", grammar, "-o", output, "--", "--executable=#{RbConfig.ruby}"), @err.string
    assert_equal 0o755, File.stat(output).mode & 0o777
  end

  def test_log_paths_cannot_alias_the_grammar_or_output
    grammar = write("parser.y", GRAMMAR)
    output = write("parser.rb", "existing parser\n")
    symlink = File.join(@dir, "grammar_link")
    hardlink = File.join(@dir, "output_link")
    File.symlink(grammar, symlink)
    File.link(output, hardlink)
    [grammar, output, symlink, hardlink].each do |path|
      [["--log-file", path], ["--log-file=#{path}"], ["-O", path], ["-O#{path}"],
       ["--log=#{path}"], ["-vO#{path}"]].each do |options|
        assert_equal 1, run_cli("generate", grammar, "-o", output, "--", *options), options.inspect
        assert_equal GRAMMAR, File.binread(grammar), options.inspect
        assert_equal "existing parser\n", File.binread(output), options.inspect
      end
    end
  end

  def test_explicit_log_destinations_still_work
    grammar = write("parser.y", GRAMMAR)
    output = File.join(@dir, "parser.rb")
    log = File.join(@dir, "parser.log")
    [["--log-file", log], ["--log=#{log}"], ["-vO#{log}"]].each do |options|
      assert_equal 0, run_cli("generate", grammar, "-o", output, "--", *options), @err.string
      assert_includes File.read(log), "state"
    end
  end

  def test_default_verbose_log_cannot_overwrite_the_grammar
    grammar = write("parser.output", GRAMMAR)
    output = write("parser.rb", "existing parser\n")
    assert_equal 1, run_cli("generate", grammar, "-o", output, "--", "--verbose")
    assert_equal GRAMMAR, File.binread(grammar)
    assert_equal "existing parser\n", File.binread(output)
  end

  def test_default_verbose_log_outside_staging_cannot_overwrite_the_grammar
    grammar = write("build.output", GRAMMAR)
    directory = File.join(@dir, "build.debug")
    FileUtils.mkdir_p(directory)
    output = File.join(directory, "parser.rb")
    assert_equal 1, run_cli("generate", grammar, "-o", output, "--", "--verbose")
    assert_equal GRAMMAR, File.binread(grammar)
    refute File.exist?(output)
  end

  def test_generated_invalid_ruby_keeps_existing_output
    grammar = write("bad_action.y", GRAMMAR.sub("result = val[0]", "result = )"))
    output = write("parser.rb", "existing parser\n")
    assert_equal 1, run_cli("generate", grammar, "-o", output)
    assert_equal "existing parser\n", File.binread(output)
  end

  def test_generate_rejects_conflicting_output_options_and_overwriting_the_grammar
    grammar = write("parser.y", GRAMMAR)
    output = write("parser.rb", "existing parser\n")
    assert_equal 1, run_cli("generate", grammar, "-o", grammar)
    assert_equal GRAMMAR, File.binread(grammar)
    assert_equal 1, run_cli("generate", grammar, "-o", output, "--", "-o", output)
    assert_equal "existing parser\n", File.binread(output)
    link = File.join(@dir, "grammar_link.rb")
    File.symlink(grammar, link)
    assert_equal 1, run_cli("generate", grammar, "-o", link)
    assert_equal GRAMMAR, File.binread(grammar)
  end

  def test_generate_preserves_racc_verbose_output
    write("parser.y", GRAMMAR)
    Dir.chdir(@dir) do
      assert_equal 0, run_cli("generate", "parser.y", "-o", "parser.rb", "--", "--verbose"), @err.string
      assert File.file?("parser.output")
      assert_includes File.read("parser.output"), "state"
    end
  end

  def test_generate_verbose_output_in_a_directory_containing_a_dot
    project = File.join(@dir, "my.project")
    FileUtils.mkdir_p(project)
    File.write(File.join(project, "parser.y"), GRAMMAR)
    Dir.chdir(project) do
      assert_equal 0, run_cli("generate", "parser.y", "-o", "parser.rb", "--", "--verbose"), @err.string
      assert File.file?("parser.output")
    end
  end

  def test_annotate_preserves_a_symlink_and_updates_its_target
    path = write("parser.rb", SOURCE)
    link = File.join(@dir, "parser_link.rb")
    File.symlink(path, link)
    assert_equal 0, run_cli("annotate", link)
    assert File.symlink?(link)
    assert_equal RaccRbsInline.annotate(SOURCE), File.binread(path)
  end

  def test_sig_copies_runtime_rbs
    output = File.join(@dir, "sig", "racc")
    assert_equal 0, run_cli("sig", "--output", output)
    assert_equal File.binread(File.expand_path("../data/racc/parser.rbs", __dir__)),
                 File.binread(File.join(output, "parser.rbs"))
    Dir.chdir(@dir) do
      assert_equal 0, run_cli("sig")
      assert File.file?("sig/racc/parser.rbs")
    end
  end

  def test_version_and_help
    assert_equal 0, run_cli("--version")
    assert_includes @out.string, RaccRbsInline::VERSION
    assert_equal 0, run_cli("--help")
    %w[annotate generate sig].each do |command|
      assert_includes @out.string, command
      assert_equal 0, run_cli(command, "--help")
    end
  end

  def test_executable
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-Ilib", "exe/racc-rbs-inline", "--version")
    assert status.success?, stderr
    assert_includes stdout, RaccRbsInline::VERSION
  end
end
