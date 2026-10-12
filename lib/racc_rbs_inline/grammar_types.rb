# frozen_string_literal: true
# rbs_inline: enabled

require "prism"
require "rbs"
require "strscan"
require "racc/grammarfileparser"

module RaccRbsInline
  class GrammarTypes
    # @rbs @rules: Array[untyped]
    # @rbs @table: untyped
    # @rbs @result_var: bool
    # @rbs @types: Hash[Symbol | String, String]

    #: (String source, ?filename: String) -> bool
    def self.declared?(source, filename: "grammar.y")
      !grammar_comment_lines(source, filename).empty?
    rescue Racc::CompileError, ArgumentError => error
      raise Error, "#{filename}: #{error.message}"
    end

    #: (String source, ?filename: String) -> void
    def initialize(source, filename: "grammar.y")
      raise Error, "Grammar is empty" if source.strip.empty?

      comment_lines = self.class.grammar_comment_lines(source, filename) { |text| literal_string(text) }
      result = Racc::GrammarFileParser.parse(source, filename)
      states = Racc::States.new(result.grammar).nfa
      states.dfa
      @table = states.state_transition_table
      @rules = []
      result.grammar.each { |rule| @rules << rule }
      @result_var = result.params.result_var?
      @types = declarations(source, comment_lines)
      known = result.grammar.symboltable.symbols.reject(&:dummy?).map(&:value)
      unknown = @types.keys - known
      raise Error, "Unknown grammar symbols: #{unknown.map(&:inspect).join(', ')}" unless unknown.empty?
    rescue Racc::CompileError, RBS::ParsingError, ArgumentError => error
      raise Error, "#{filename}: #{error.message}"
    end

    #: (body: Prism::StatementsNode) -> Hash[Symbol, String]
    def signatures(body:)
      validate_tables(body)
      signatures = {} #: Hash[Symbol, String]
      return signatures if @types.empty?

      body.body.each do |node|
        next unless node.is_a?(Prism::DefNode)
        match = node.name.to_s.match(/\A_reduce_(\d+)\z/)
        next unless match

        rule = @rules[match[1].to_i]
        raise Error, "Reduction #{node.name} does not exist in the grammar" unless rule
        next if rule.target.dummy?

        expected = @result_var ? 3 : 2
        raise Error, "Reduction #{node.name} parameters do not match the grammar" unless node.parameters&.requireds&.length == expected

        types = rule.symbols.map { |symbol| type_for(symbol) } #: Array[String]
        target = type_for(rule.target)
        parameters = "[#{types.join(', ')}] val, Array[untyped] _values"
        if @result_var
          first = types.first || "nil"
          parameters += ", #{union(first, target)} result"
        end
        signatures[node.name] = "#: (#{parameters}) -> #{target}"
      end
      signatures
    end

    private

    #: (String source, String filename) ?{ (String) -> String } -> Array[Integer]
    def self.grammar_comment_lines(source, filename, &decode)
      scanner = Racc::GrammarFileScanner.new(source, filename)
      raise Error, "Grammar has no rules" unless scanner.instance_variable_get(:@line)
      # Never let Racc evaluate tokens while locating declaration comments.
      scanner.define_singleton_method(:eval) { |text| decode ? decode.call(text) : text }
      lines = [] #: Array[Integer]
      record = lambda do
        line = scanner.instance_variable_get(:@line) #: String?
        if scanner.instance_variable_get(:@in_block).nil? && line&.match?(/\A\s*#\s*@racc-type\b/)
          lines << scanner.lineno
        end
      end
      advance = scanner.method(:next_line)
      scanner.define_singleton_method(:next_line) do
        available = advance.call
        record.call if available
        available
      end
      record.call
      scanner.yylex { |_token| }
      lines
    end

    #: (String source, Array[Integer] comment_lines) -> Hash[Symbol | String, String]
    def declarations(source, comment_lines)
      types = {} #: Hash[Symbol | String, String]
      lines = source.lines
      comment_lines.each do |number|
        line = lines.fetch(number - 1)
        match = line.match(/\A\s*#\s*@racc-type\b(.*)/)
        next unless match

        scanner = StringScanner.new(match[1])
        symbols = [] #: Array[Symbol | String]
        loop do
          scanner.skip(/\s*/)
          break if scanner.scan(/:/)
          token = scanner.scan(/[A-Za-z_]\w*|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'/)
          raise Error, "Invalid @racc-type declaration on line #{number}" unless token
          symbols << (token.start_with?("'", '"') ? literal_string(token).b : token.to_sym)
          unless scanner.eos? || scanner.peek(1).match?(/[\s:]/)
            raise Error, "Invalid @racc-type symbols on line #{number}"
          end
        end
        raise Error, "Missing symbols in @racc-type on line #{number}" if symbols.empty?

        type = parse_type(scanner.rest.strip).to_s
        symbols.each do |symbol|
          if types.key?(symbol) && types[symbol] != type
            raise Error, "Conflicting types for #{symbol.inspect} on line #{number}"
          end
          types[symbol] = type
        end
      end
      types
    end

    #: (String source) -> String
    def literal_string(source)
      parsed = Prism.parse(source)
      nodes = parsed.value.statements.body
      node = nodes.first
      unless parsed.success? && nodes.length == 1 && node.is_a?(Prism::StringNode)
        raise Error, "Grammar symbols must be literal strings without interpolation"
      end
      node.unescaped
    end

    #: (untyped symbol) -> String
    def type_for(symbol)
      return @types.fetch(symbol.value, "untyped") unless symbol.dummy?

      case symbol.value.to_s
      when /\A-option@/
        rule = @rules.find { |candidate| candidate.target == symbol && !candidate.symbols.empty? }
        inner = parse_type(type_for(rule.symbols.first))
        RBS::Types::Optional.new(type: inner, location: nil).to_s
      when /\A-many1?@/
        rule = @rules.find { |candidate| candidate.target == symbol && !candidate.symbols.empty? }
        "Array[#{type_for(rule.symbols.first)}]"
      when /\A-group@/
        "Array[untyped]"
      else
        "untyped"
      end
    end

    #: (String first, String target) -> String
    def union(first, target)
      return target if first == target

      types = [first, target].map { |type| parse_type(type) }
      RBS::Types::Union.new(types: types, location: nil).to_s
    end

    #: (String source) -> RBS::Types::t
    def parse_type(source)
      RBS::Parser.parse_type(source, require_eof: true, void_allowed: false) || raise(Error, "Missing RBS type in @racc-type declaration")
    end

    #: (Prism::StatementsNode body) -> void
    def validate_tables(body)
      expected = {
        racc_action_table: @table.action_table,
        racc_action_check: @table.action_check,
        racc_action_default: @table.action_default,
        racc_action_pointer: @table.action_pointer,
        racc_goto_table: @table.goto_table,
        racc_goto_check: @table.goto_check,
        racc_goto_default: @table.goto_default,
        racc_goto_pointer: @table.goto_pointer,
        racc_reduce_table: @table.reduce_table,
        racc_reduce_n: @rules.length,
        racc_nt_base: @table.nt_base,
        racc_use_result_var: @result_var,
        Racc_token_to_s_table: @table.token_to_s_table
      } #: Hash[Symbol, untyped]
      expected.each do |name, value|
        nodes = body.body.select do |node|
          (node.is_a?(Prism::LocalVariableWriteNode) || node.is_a?(Prism::ConstantWriteNode)) && node.name == name
        end
        node = nodes.first
        unless nodes.length == 1 && (node.is_a?(Prism::LocalVariableWriteNode) || node.is_a?(Prism::ConstantWriteNode)) && literal(node.value) == value
          raise Error, "Generated #{name} does not match the grammar; regenerate with the same Racc version"
        end
      end
    end

    #: (Prism::Node node) -> untyped
    def literal(node)
      case node
      when Prism::ArrayNode then node.elements.map { |element| literal(element) }
      when Prism::IntegerNode then node.value
      when Prism::SymbolNode then node.unescaped.to_sym
      when Prism::StringNode then node.unescaped
      when Prism::TrueNode then true
      when Prism::FalseNode then false
      when Prism::NilNode then nil
      else
        raise Error, "Generated grammar tables must contain only literals"
      end
    end
  end
end
