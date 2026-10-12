# frozen_string_literal: true

require_relative "test_helper"
require "rbs"
require "racc/parser"

class RuntimeSignatureTest < Minitest::Test
  def test_all_runtime_methods_have_signatures_with_matching_visibility
    loader = RBS::EnvironmentLoader.new
    loader.add(path: Pathname(File.expand_path("../data/racc", __dir__)))
    environment = RBS::Environment.from_loader(loader).resolve_type_names
    name = RBS::TypeName.new(name: :Parser, namespace: RBS::Namespace.parse("::Racc::"))
    definition = RBS::DefinitionBuilder.new(env: environment).build_instance(name)

    [:public, :private, :protected].each do |visibility|
      Racc::Parser.public_send("#{visibility}_instance_methods", false).each do |method|
        signature = definition.methods[method]
        refute_nil signature, "Missing signature for #{method}"
        assert_equal visibility, signature.accessibility, method.to_s
      end
    end
  end

  def test_gem_contains_runtime_types_without_automatically_loading_them
    spec = Gem::Specification.load(File.expand_path("../racc-rbs-inline.gemspec", __dir__))
    assert_includes spec.files, "data/racc/parser.rbs"
    Dir[File.expand_path("../sig/**/*.rbs", __dir__)].each do |path|
      refute_match(/^module Racc\b/, File.read(path))
    end
    assert_equal %w[prism racc rbs], spec.runtime_dependencies.map(&:name)
  end

  def test_gem_signatures_load_their_optional_rake_dependency
    loader = RBS::EnvironmentLoader.new
    loader.repository.add(Pathname(File.expand_path("../.gem_rbs_collection", __dir__)))
    loader.add(library: "racc-rbs-inline")
    environment = RBS::Environment.from_loader(loader).resolve_type_names
    name = RBS::TypeName.new(name: :RakeTask, namespace: RBS::Namespace.parse("::RaccRbsInline::"))
    definition = RBS::DefinitionBuilder.new(env: environment).build_instance(name)
    assert definition.methods.key?(:initialize)
    spec = Gem::Specification.load(File.expand_path("../racc-rbs-inline.gemspec", __dir__))
    assert_includes spec.files, "sig/manifest.yaml"
  end
end
