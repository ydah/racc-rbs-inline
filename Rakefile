# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |task|
  task.libs << "test"
  task.pattern = "test/**/*_test.rb"
end

desc "Generate this gem's RBS from inline annotations"
task :rbs do
  sh "bundle", "exec", "rbs-inline", "--output=sig/generated", "lib"
end

desc "Check this gem's types"
task typecheck: :rbs do
  sh "bundle", "exec", "rbs", "--no-collection", "-I", "data/racc", "validate"
  sh "bundle", "exec", "steep", "check", "-j", "2"
end

task default: [:test, :typecheck]
