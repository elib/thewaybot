require 'active_record'
require 'yaml'

env = "development"
config = YAML.load(File.read('db/config.yml'));
ActiveRecord::Base.establish_connection config[env];

Dir.glob('./model/*.rb').each do |file|
	require file
end