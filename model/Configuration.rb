class Configuration < ActiveRecord::Base
	def self.setup
		conf = Configuration.all.first
		if(conf.nil?) then
			conf = Configuration.create
		end
		
		return conf;
	end
end