# frozen_string_literal: true

require_relative "lib/racc_rbs_inline/version"

Gem::Specification.new do |spec|
  spec.name = "racc-rbs-inline"
  spec.version = RaccRbsInline::VERSION
  spec.authors = ["Yudai Takada"]
  spec.email = ["t.yudai92@gmail.com"]
  spec.summary = "Add inline RBS types to Racc-generated parsers"
  spec.description = "Annotates Racc parser tables and reduction methods for rbs-inline and Steep without changing Racc."
  spec.homepage = "https://github.com/ydah/racc-rbs-inline"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["source_code_uri"] = spec.homepage
  spec.files = Dir["lib/**/*.rb", "exe/*", "data/**/*.rbs", "sig/**/*.rbs", "sig/manifest.yaml", "README.md", "LICENSE.txt"]
  spec.bindir = "exe"
  spec.executables = ["racc-rbs-inline"]
  spec.require_paths = ["lib"]
  spec.add_dependency "prism", ">= 1.0"
end
