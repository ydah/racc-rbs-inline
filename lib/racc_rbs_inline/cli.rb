# frozen_string_literal: true
# rbs_inline: enabled

require "fileutils"
require "open3"
require "optparse"
require "rbconfig"
require "tempfile"
require "tmpdir"
require_relative "../racc_rbs_inline"

module RaccRbsInline
  class CLI
    HELP = <<~TEXT
      Usage: racc-rbs-inline COMMAND [OPTIONS]

        annotate [--stdout | --check] FILE...
        generate GRAMMAR -o OUT [-- RACC_OPTIONS]
        sig [--output DIR]                         (default: sig/racc)
        --version
        --help
    TEXT

    # @rbs @out: untyped
    # @rbs @err: untyped

    #: (Array[String] argv, ?out: untyped, ?err: untyped) -> Integer
    def self.run(argv, out: $stdout, err: $stderr)
      new(out: out, err: err).run(argv)
    end

    #: (out: untyped, err: untyped) -> void
    def initialize(out:, err:)
      @out = out
      @err = err
    end

    #: (Array[String] argv) -> Integer
    def run(argv)
      args = argv.dup
      case args.shift
      when "annotate" then annotate(args)
      when "generate" then generate(args)
      when "sig" then sig(args)
      when "--version", "-v"
        raise Error, "unexpected arguments" unless args.empty?
        @out.puts(VERSION)
        0
      when "--help", "-h"
        @out.puts(HELP)
        0
      else
        raise Error, HELP
      end
    rescue Error, OptionParser::ParseError, SystemCallError, IOError => error
      @err.puts("racc-rbs-inline: #{error.message}")
      1
    end

    private

    #: (Array[String] args) -> Integer
    def annotate(args)
      stdout = false
      check = false
      parser = OptionParser.new do |options|
        options.banner = "Usage: racc-rbs-inline annotate [--stdout | --check] FILE..."
        options.on("--stdout", "Write annotated source to standard output") { stdout = true }
        options.on("--check", "List files needing annotation without writing") { check = true }
        options.on("-h", "--help") { @out.puts(options); return 0 }
      end
      parser.parse!(args)
      raise Error, "annotate requires at least one file" if args.empty?
      raise Error, "--stdout and --check cannot be combined" if stdout && check

      # Validate every input before replacing any of them.
      results = args.map do |path|
        source = File.binread(path)
        [path, source, RaccRbsInline.annotate(source)]
      rescue Error => error
        raise Error, "#{path}: #{error.message}"
      end #: Array[[String, String, String]]
      changed = false
      results.each do |path, source, annotated|
        if stdout
          @out.write(annotated)
        elsif source != annotated
          changed = true
          if check
            @out.puts(path)
          else
            replace(path, annotated, File.stat(path).mode)
          end
        end
      end
      check && changed ? 1 : 0
    end

    #: (Array[String] args) -> Integer
    def generate(args)
      separator = args.index("--")
      racc_options = [] #: Array[String]
      if separator
        racc_options = args.drop(separator + 1)
        args = args.take(separator)
      end
      output_option = nil #: String?
      parser = OptionParser.new do |options|
        options.banner = "Usage: racc-rbs-inline generate GRAMMAR -o OUT [-- RACC_OPTIONS]"
        options.on("-o", "--output FILE") { |path| output_option = path }
        options.on("-h", "--help") { @out.puts(options); return 0 }
      end
      parser.parse!(args)
      output = output_option || raise(Error, "generate requires -o OUT")
      raise Error, "generate requires one grammar" unless args.length == 1
      grammar = args.fetch(0)
      if same_file?(grammar, output)
        raise Error, "grammar and output must be different files"
      end
      raise Error, "pass the output path with -o before --" if racc_options.any? { |option| option == "--" || option.match?(/\A(?:-o|--output-file(?:=|\z))/) }
      default_log = validate_log_paths(racc_options, grammar, output)

      Dir.mktmpdir("racc-rbs-inline-", File.expand_path(File.dirname(output))) do |directory|
        generated = File.join(directory, File.basename(output))
        if File.exist?(output)
          File.write(generated, "")
          File.chmod(File.stat(output).mode & 0o777, generated)
        end
        # Racc derives verbose log names from the first dot in the output path.
        racc_output = generated.delete_prefix("#{Dir.pwd}/")
        validate_log_path(racc_output.sub(/(?:\..*?)?\z/, ".output"), grammar, output) if default_log
        stdout, stderr, status = Open3.capture3(*racc_command, *racc_options, "-o", racc_output, grammar)
        @out.write(stdout)
        @err.write(stderr)
        return status.exitstatus || 1 unless status.success?

        annotated = RaccRbsInline.annotate(File.binread(generated))
        # Racc's --verbose option also produces a .output file beside the parser.
        artifacts = Dir.children(directory).reject { |name| name == File.basename(generated) }
        artifacts.each do |name|
          validate_log_path(File.join(File.dirname(output), name), grammar, output)
        end
        replace(output, annotated, File.stat(generated).mode)
        artifacts.each do |name|
          File.rename(File.join(directory, name), File.join(File.dirname(output), name))
        end
      end
      0
    end

    #: (Array[String] options, String grammar, String output) -> bool
    def validate_log_paths(options, grammar, output)
      remaining = options.dup
      verbose = false
      explicit_log = false
      parser = OptionParser.new do |flags|
        flags.on("-O", "--log-file FILE") do |path|
          validate_log_path(path, grammar, output)
          explicit_log = true
        end
        flags.on("-v", "--verbose") { verbose = true }
        # Recognize argument boundaries and short clusters; Racc validates all other options.
        flags.on("-e", "--executable [PATH]") {}
        flags.on("-o", "--output-file FILE") {}
        flags.on("-D FLAGS") {}
        flags.on("--superclass CLASS") {}
        %w[-t -g -E -F -l -a -C -S -P --help --version].each { |flag| flags.on(flag) {} }
      end
      until remaining.empty?
        begin
          parser.order!(remaining) {}
        rescue OptionParser::InvalidOption
          next
        end
      end
      verbose && !explicit_log
    end

    #: (String path, String grammar, String output) -> void
    def validate_log_path(path, grammar, output)
      if same_file?(path, grammar) || same_file?(path, output)
        raise Error, "Racc log file must differ from grammar and output: #{path}"
      end
    end

    #: (String first, String second) -> bool
    def same_file?(first, second)
      File.realdirpath(first) == File.realdirpath(second) || File.identical?(first, second)
    end

    #: () -> Array[String]
    def racc_command
      [RbConfig.ruby, Gem.bin_path("racc", "racc")]
    rescue Gem::LoadError, RuntimeError
      ["racc"]
    end

    #: (Array[String] args) -> Integer
    def sig(args)
      output = "sig/racc"
      parser = OptionParser.new do |options|
        options.banner = "Usage: racc-rbs-inline sig [--output DIR]"
        options.on("-o", "--output DIR") { |path| output = path }
        options.on("-h", "--help") { @out.puts(options); return 0 }
      end
      parser.parse!(args)
      raise Error, "sig does not take positional arguments" unless args.empty?
      source = File.binread(File.expand_path("../../data/racc/parser.rbs", File.dirname(__FILE__)))
      FileUtils.mkdir_p(output)
      path = File.join(output, "parser.rbs")
      mode = File.exist?(path) ? File.stat(path).mode : 0o666 & ~File.umask
      replace(path, source, mode)
      0
    end

    #: (String path, String source, Integer mode) -> void
    def replace(path, source, mode)
      path = File.realpath(path) if File.symlink?(path)
      Tempfile.create([".racc-rbs-inline-", ".tmp"], File.dirname(path)) do |file|
        file.binmode
        file.write(source)
        file.flush
        File.chmod(mode & 0o777, file.path)
        File.rename(file.path, path)
      end
    end
  end
end
