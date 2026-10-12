# frozen_string_literal: true
# rbs_inline: enabled

require "prism"

module RaccRbsInline
  class Annotator
    MAGIC = "# rbs_inline: enabled" #: String
    INTEGER_TABLE = /\Aracc_(?:action|goto)_(?:table|check|pointer|default)\z/ #: Regexp
    REDUCTION = /\A_reduce_(?:\d+|none)\z/ #: Regexp
    CONSTANT_TYPES = {
      Racc_arg: "::Racc::Parser::racc_arg",
      Racc_token_to_s_table: "Array[String]",
      Racc_debug_parser: "bool"
    }.freeze #: Hash[Symbol, String]

    #: (String source) -> String
    def annotate(source)
      return source if annotated?(source)

      source = unwrap(source)
      source = add_annotations(source)
      add_magic_comment(source)
    end

    #: (String source) -> bool
    def annotated?(source)
      return false unless source.include?(MAGIC)

      Prism.parse(source).comments.any? { |comment| comment.location.slice.strip == MAGIC }
    end

    private

    #: (String source) -> String
    def unwrap(source)
      edits = [] #: Array[[Integer, Integer, String]]
      binary = source.b
      parser_bodies(parse!(source)).each do |body|
        body.body.each do |statement|
          next unless statement.is_a?(Prism::CallNode) && statement.name == :module_eval && statement.receiver.nil?

          heredoc = statement.arguments&.arguments&.first
          next unless heredoc.is_a?(Prism::StringNode) && heredoc.heredoc?
          closing = heredoc.closing_loc
          next unless closing

          start = line_start(binary, statement.location.start_offset)
          edits << [start, closing.end_offset, heredoc.content_loc.slice.b]
        end
      end
      apply(source, edits)
    end

    #: (String source) -> String
    def add_annotations(source)
      edits = [] #: Array[[Integer, Integer, String]]
      binary = source.b
      parser_bodies(parse!(source)).each do |body|
        body.body.each do |statement|
          case statement
          when Prism::LocalVariableWriteNode
            type = table_type(statement)
            edits << trailing(statement, type) if type
          when Prism::ConstantWriteNode
            type = CONSTANT_TYPES[statement.name]
            edits << trailing(statement, type) if type
          when Prism::DefNode
            next unless statement.name.to_s.match?(REDUCTION)

            count = statement.parameters&.requireds&.size
            unless [2, 3].include?(count)
              raise Error, "Unsupported parameters for #{statement.name}: expected two or three required parameters"
            end
            parameters = "Array[untyped] val, Array[untyped] _values"
            parameters += ", untyped result" if count == 3
            start = line_start(binary, statement.location.start_offset)
            indent = binary.byteslice(start, statement.location.start_offset - start)
            edits << [start, start, "#{indent}#: (#{parameters}) -> untyped#{newline(source)}".b]
          end
        end
      end
      apply(source, edits)
    end

    #: (Prism::LocalVariableWriteNode node) -> String?
    def table_type(node)
      name = node.name.to_s
      return "Array[Integer?]" if name.match?(INTEGER_TABLE)
      return "Array[Integer | Symbol]" if name == "racc_reduce_table"
      return unless name == "racc_token_table"

      literal = node.value.is_a?(Prism::HashNode) && node.value.elements.all? do |element|
        element.is_a?(Prism::AssocNode) &&
          [Prism::SymbolNode, Prism::StringNode, Prism::FalseNode].any? { |type| element.key.is_a?(type) }
      end
      literal ? "Hash[::Racc::Parser::token_symbol, Integer]" : "Hash[untyped, Integer]"
    end

    #: (Prism::Node node, String type) -> [Integer, Integer, String]
    def trailing(node, type)
      offset = node.location.end_offset
      [offset, offset, " #: #{type}".b]
    end

    #: (String source) -> String
    def add_magic_comment(source)
      offset = 0
      source.b.each_line do |line|
        break unless line.start_with?("#!") || line.match?(/\A#[^\r\n]*(?:frozen[_-]string[_-]literal\s*:|(?:coding|encoding)\s*[:=])/i)

        offset += line.bytesize
      end
      apply(source, [[offset, offset, "#{MAGIC}#{newline(source)}".b]])
    end

    #: (String source) -> String
    def newline(source)
      source.include?("\r\n") ? "\r\n" : "\n"
    end

    #: (String source) -> Prism::ProgramNode
    def parse!(source)
      result = Prism.parse(source)
      if result.failure?
        details = result.errors.map { |error| "line #{error.location.start_line}: #{error.message}" }.join(", ")
        raise Error, "Invalid Ruby source: #{details}"
      end
      result.value
    end

    #: (Prism::ProgramNode program) -> Array[Prism::StatementsNode]
    def parser_bodies(program)
      bodies = [] #: Array[Prism::StatementsNode]
      pending = [program] #: Array[Prism::Node]
      while (node = pending.pop)
        if node.is_a?(Prism::ClassNode) && node.body.is_a?(Prism::StatementsNode) &&
            node.body.body.any? { |statement| statement.is_a?(Prism::ConstantWriteNode) && statement.name == :Racc_arg }
          bodies << node.body
        end
        pending.concat(node.compact_child_nodes)
      end
      raise Error, "Racc parser class not found" if bodies.empty?

      bodies
    end

    #: (String binary, Integer offset) -> Integer
    def line_start(binary, offset)
      return 0 if offset.zero?

      previous = binary.rindex("\n", offset - 1)
      previous ? previous + 1 : 0
    end

    #: (String source, Array[[Integer, Integer, String]] edits) -> String
    def apply(source, edits)
      binary = source.b
      edits.sort_by { |start, _, _| -start }.each do |start, finish, replacement|
        binary[start...finish] = replacement
      end
      binary.force_encoding(source.encoding)
    end
  end
end
