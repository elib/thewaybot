require 'rubygems'

require 'twitter'
require 'time'
require 'json'
require 'yaml'
require 'logger'
require './environment'

require 'nokogiri'
require 'fileutils'
require 'neocitizen'

require "../lib/wordfilter/lib/wordfilter"

@logger = Logger.new('thewaybot_log.txt', 'weekly')

#load configuration from config.yml -- you must provide this file yourself
twitter_config = YAML.load_file('config.yml')

client1 = Twitter::Streaming::Client.new do |config|
  config.consumer_key = twitter_config["consumer_key"]
  config.consumer_secret = twitter_config["consumer_secret"]
  config.access_token = twitter_config["oauth_token"]
  config.access_token_secret = twitter_config["oauth_token_secret"]
end

#second twitter client -- REST (for writing tweets)
write_client = Twitter::REST::Client.new do |config|
  config.consumer_key = twitter_config["consumer_key"]
  config.consumer_secret = twitter_config["consumer_secret"]
  config.access_token = twitter_config["oauth_token"]
  config.access_token_secret = twitter_config["oauth_token_secret"]
end

neocities_config = {
	username: twitter_config["neocities_username"],
	password: twitter_config["neocities_password"]
}

#main method for running the collection engine
def start_tracking(phrase_text, client, write_client)
	#build phrase regex
	phrase_test = Regexp.new(phrase_text + "([^\\.\\?\\!#\\@](?<!http|$))+(\\.|\\!|\\Z)", Regexp::IGNORECASE | Regexp::MULTILINE);
	
	#Stolen from stack overflow, quick and simple way to remove all ambiguous unicode chars.
	encoding_options = {
		:invalid           => :replace,  # Replace invalid byte sequences
		:undef             => :replace,  # Replace anything not defined in ASCII
		:replace           => '',        # Use a blank for those replacements
		:universal_newline => true       # Always break lines with \n
	}
	
	#not sure the < and > ones are necessary. But the &amp; -> & certainly was. Is this a JSON thing?
	to_replace = [
			["&amp;", "&"],
			["&lt;", "<"],
			["&gt;", ">"]
		]
	
	#limit tweeting to once every 90 seconds. This is just under the 1000 tweets/day rule.
	timeout = 90;
	next_tweet = Time.now;
	
	#start listening to the basic phrase query
	client.filter(:track => phrase_text) do |tweet|
		
		#apply fancy regex
		sub = tweet.text[phrase_test];
		if(!sub.nil?) then
			
			#remove unicode as defined above
			sub = sub.encode Encoding.find('ASCII'), encoding_options
			
			#replace special entities as defined above
			to_replace.each { |rep| 
				sub.gsub!(rep[0], rep[1]);
			}
			
			#separately, save a compact version of this phrase for testing against already-seen list
				phrase = sub.clone;
				#remove all punctuation
				phrase.gsub!(/[[:punct:]]/, "");
				#remove all whitespace
				phrase.gsub!(/\s/, "");
				#force all to lowercase
				phrase.downcase!
			
			#check against already-seen database
			if(Phrase.where(:phrase_letters => phrase).count == 0 && Phrase.where(:user_id => tweet.user.id).count == 0) then
				#add some punctuation bells and whistles to make prettier:
					#add period if no ending punctuation
					sub << "." if sub !~ /[[:punct:]]$/
					#begin with a capital
					sub[0] = sub[0].upcase;
					#remove whitespace before the final punctuation
					sub.gsub!(/\s*([[:punct:]]+$)/, '\1');

				if(Wordfilter::blacklisted? sub) then
					@logger.info("Filtered blacklisted content. Tweet aborted. Content was: #{sub}");
					next;
				end
				
				#check if we can tweet this phrase
				if Time.now >= next_tweet then
					#tweet it
					@logger.info("\tTweeting: #{sub}");
					bot_tweet = write_client.update(sub);
					
					#Save this pretty phrase to the novel phrase list
					@logger.info("Saving to database: #{sub}");
					Phrase.create(:user_id => tweet.user.id,
								:phrase => sub,
								:phrase_letters => phrase,
								:source_tweet_id => tweet.id,
								:source_tweet_time => tweet.created_at,
								:user_handle => tweet.user.handle,
								:bot_tweet_id => bot_tweet.id)
					
					next_tweet = Time.now + timeout;
				end
			end
		end
	end
end

def create_html(neocities_config)
	@logger.info("Performing HTML generation job");

	phrases_to_do = Phrase.where.not(:source_tweet_id => nil).
					where(:created_at => (Configuration.first.last_tweet_archived..Time.new)).
					order(:created_at => :asc)
					
	@logger.info("#{phrases_to_do.count} phrases to output.");
	return if(phrases_to_do.count == 0);
	
	week_number = Date.today.cweek
	year_number = Date.today.year
	html_name = "#{year_number}_#{"%02d" % week_number}.html"
	filename = "html/#{html_name}";
	if(!File.exists?(filename)) then
		@logger.info("Opening new archive week.");
		FileUtils.cp "html/template.html", filename
		should_update_index = true;
	else
		should_update_index = false;
	end
	
	previous_file_text = File.open(filename, "r") { |f| f.read };
	index_filename = "html/index.html"
	if(should_update_index) then
		previous_file_text.gsub!("(WEEK_NUMBER)", week_number.to_s);
		previous_file_text.gsub!("(YEAR_NUMBER)", year_number.to_s);
		
		previous_index_text = File.open(index_filename) {|f| f.read}
		doc = Nokogiri::HTML::Document.parse(previous_index_text);
		
		fragment = Nokogiri::HTML::DocumentFragment.parse ""
		Nokogiri::HTML::Builder.with(fragment) do |fr|
			fr.div.entry {
				fr.div.text {
					fr.a.page_link(:href => "#{html_name}") {
						fr << "Week #{week_number}, #{year_number}"
					}
				}
			}
		end
		
		new_node = fragment.to_html
		content_div = doc.at_css("div#content")
		content_div.prepend_child new_node
		
		current_file = File.open(index_filename, "w");
		current_file.write(doc.to_html);
		current_file.close;
	end
	
	doc = Nokogiri::HTML::Document.parse(previous_file_text);
	
	phrases_to_do.each{ |p|
		fragment = Nokogiri::HTML::DocumentFragment.parse ""
		Nokogiri::HTML::Builder.with(fragment) do |fr|
			fr.div.entry {
				fr.div.text {
					fr.text p.phrase
					fr.a.bot_tweet_link(:href => "https://twitter.com/thewaybot/status/#{p.bot_tweet_id}", :title => "link to @thewaybot tweet") {
						fr << "&nbsp;"
					}
					fr.a.source_tweet_link(:href => "https://twitter.com/#{p.user_handle}/status/#{p.source_tweet_id}", :title => "link to source tweet by #{p.user_handle}") {
						fr << "&nbsp;"
					}
				}
			}
		end
		
		new_node = fragment.to_html
		
		content_div = doc.at_css("div#content")
		content_div.prepend_child new_node
	}
	
	current_file = File.open(filename, "w");
	current_file.write(doc.to_html);
	current_file.close;
	
	Configuration.first.update(:last_tweet_archived => phrases_to_do.last.created_at);
	
	@logger.info("Done writing HTML file. Uploading.")
	
	client = Neocitizen::Client.new(username: neocities_config[:username], password: neocities_config[:password])
	client.upload(filename)
	if(should_update_index) then
		client.upload(index_filename);
	end
	
	@logger.info("Files successfully uploaded.");
end

Configuration.setup

# ** STARTUP ** #
@logger.info("starting!")

begin
	create_html(neocities_config)
	start_tracking("I like it when", client1, write_client)
rescue Exception => e
	ProcessUtilities.report_exception(e, @logger);
end