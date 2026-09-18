# frozen_string_literal: true

require 'rake/testtask'

Rake::TestTask.new(:test) do |t|
  t.libs << 'lib' << 'test'
  t.test_files = FileList['test/**/*_test.rb']
  t.warning = false
end

desc 'Run the counter example'
task :counter do
  ruby '-Ilib examples/counter.rb'
end

task default: :test
