require File.expand_path(File.dirname(__FILE__) + "/spec_helper")
require 'socket'
require 'fileutils'
require 'support/apache2_controller'
PhusionPassenger.require_passenger_lib 'platform_info'
PhusionPassenger.require_passenger_lib 'admin_tools'
PhusionPassenger.require_passenger_lib 'admin_tools/server_instance'

require 'integration_tests/mycook_spec'
require 'integration_tests/cgi_environment_spec'
require 'integration_tests/hello_world_rack_spec'
require 'integration_tests/hello_world_wsgi_spec'

# TODO: test the 'PassengerUserSwitching' and 'PassengerDefaultUser' option.
# TODO: test custom page caching directory

describe "Apache 2 module" do
	before :all do
		check_hosts_configuration
		@passenger_temp_dir = "/tmp/passenger-test.#{$$}"
		Dir.mkdir(@passenger_temp_dir)
		ENV['PASSENGER_TEMP_DIR'] = @passenger_temp_dir
	end
	
	after :all do
		@apache2.stop if @apache2
		FileUtils.chmod_R(0777, @passenger_temp_dir)
		FileUtils.rm_rf(@passenger_temp_dir)
	end
	
	before :each do
		File.open("test.log", "a") do |f|
			# Make sure that all Apache log output is prepended by the test description
			# so that we know which messages are associated with which tests.
			f.puts "\n#### #{Time.now}: #{example.full_description}"
		end
	end

	def create_apache2_controller
		@apache2 = Apache2Controller.new
		@apache2.set(:passenger_temp_dir => @passenger_temp_dir)
		if Process.uid == 0
			@apache2.set(
				:www_user => CONFIG['normal_user_1'],
				:www_group => Etc.getgrgid(Etc.getpwnam(CONFIG['normal_user_1']).gid).name
			)
		end
	end
	
	describe ": MyCook(tm) beta running on root URI" do
		before :all do
			create_apache2_controller
			@web_server_supports_chunked_transfer_encoding = true
			@base_uri = ""
			@server = "http://passenger.test:#{@apache2.port}"
			@apache2 << "RailsMaxPoolSize 1"
			@stub = ClassicRailsStub.new('rails_apps/2.3/mycook')
			@apache2.set_vhost("passenger.test", "#{@stub.full_app_root}/public")
			@apache2.start
		end
		
		after :all do
			@stub.destroy
			@apache2.stop if @apache2
		end
		
		before :each do
			@stub.reset
		end
		
		it_should_behave_like "MyCook(tm) beta"
		include_examples "CGI environment variables compliance"
		
		it "doesn't block Rails while an upload is in progress" do
			get('/') # Force spawning so that the timeout below is enough.
			
			socket = TCPSocket.new('passenger.test', @apache2.port)
			begin
				socket.write("POST / HTTP/1.1\r\n")
				socket.write("Host: passenger.test\r\n")
			
				upload_data = File.read("stub/upload_data.txt")
				size_of_first_half = upload_data.size / 2
			
				socket.write(upload_data[0..size_of_first_half])
				socket.flush
				
				Timeout.timeout(10) do
					get('/').should =~ /Welcome to MyCook/
				end
			ensure
				socket.close rescue nil
			end
		end
		
		it "doesn't block Rails while a large number of uploads are in progress" do
			get('/') # Force spawning so that the timeout below is enough.
			sockets = []
			
			upload_data = File.read("stub/upload_data.txt")
			size_of_first_half = upload_data.size / 2
			
			begin
				9.times do |i|
					socket = TCPSocket.new('passenger.test', @apache2.port)
					sockets << socket
					socket.write("POST / HTTP/1.1\r\n")
					socket.write("Host: passenger.test\r\n")
					socket.write(upload_data[0..size_of_first_half])
					socket.flush
				end
				Timeout.timeout(10) do
					get('/').should =~ /Welcome to MyCook/
				end
			ensure
				sockets.each do |socket|
					socket.close rescue nil
				end
			end
		end
		
		it "appends an X-Powered-By header containing the Phusion Passenger version number" do
			response = get_response('/')
			response["X-Powered-By"].should include("Phusion Passenger")
			response["X-Powered-By"].should include(PhusionPassenger::VERSION_STRING)
		end
	end
	
	describe ": MyCook(tm) beta running in a sub-URI" do
		before :all do
			create_apache2_controller
			@web_server_supports_chunked_transfer_encoding = true
			@base_uri = "/mycook"
			@stub = ClassicRailsStub.new('rails_apps/2.3/mycook')
			FileUtils.rm_rf('tmp.webdir')
			FileUtils.mkdir_p('tmp.webdir')
			FileUtils.cp_r('stub/zsfa/.', 'tmp.webdir')
			FileUtils.ln_sf(@stub.full_app_root + "/public", 'tmp.webdir/mycook')
			
			@apache2.set_vhost('passenger.test', File.expand_path('tmp.webdir')) do |vhost|
				vhost << "RailsBaseURI /mycook"
			end
			@apache2.start
		end
		
		after :all do
			FileUtils.rm_rf('tmp.webdir')
			@stub.destroy
			@apache2.stop if @apache2
		end
		
		before :each do
			@server = "http://passenger.test:#{@apache2.port}/mycook"
			@stub.reset
		end
		
		it_should_behave_like "MyCook(tm) beta"
		include_examples "CGI environment variables compliance"
		
		it "does not interfere with the root website" do
			@server = "http://passenger.test:#{@apache2.port}"
			get('/').should =~ /Zed, you rock\!/
		end
	end
	
	describe "compatibility with other modules" do
		before :all do
			create_apache2_controller
			@apache2 << "RailsMaxPoolSize 1"
			
			@mycook = ClassicRailsStub.new('rails_apps/2.3/mycook')
			@mycook_url_root = "http://1.passenger.test:#{@apache2.port}"
			@apache2.set_vhost("1.passenger.test", "#{@mycook.full_app_root}/public") do |vhost|
				vhost << "RewriteEngine on"
				vhost << "RewriteRule ^/rewritten_welcome$ /welcome [PT,QSA,L]"
				vhost << "RewriteRule ^/rewritten_cgi_environment$ /welcome/cgi_environment [PT,QSA,L]"
			end
			@apache2.start
		end
		
		after :all do
			@mycook.destroy
			@apache2.stop if @apache2
		end
		
		before :each do
			@mycook.reset
			@server = @mycook_url_root
		end
		
		it "supports environment variable passing through mod_env" do
			File.write("#{@mycook.app_root}/public/.htaccess", 'SetEnv FOO "Foo Bar!"')
			File.touch("#{@mycook.app_root}/tmp/restart.txt")  # Activate ENV changes.
			get('/welcome/environment').should =~ /FOO = Foo Bar\!/
			get('/welcome/cgi_environment').should =~ /FOO = Foo Bar\!/
		end
		
		it "supports mod_rewrite in the virtual host block" do
			get('/rewritten_welcome').should =~ /Welcome to MyCook/
			cgi_envs = get('/rewritten_cgi_environment?foo=bar+baz')
			cgi_envs.should include("REQUEST_URI = /welcome/cgi_environment?foo=bar+baz\n")
			cgi_envs.should include("PATH_INFO = /welcome/cgi_environment\n")
		end
		
		it "supports mod_rewrite in .htaccess" do
			File.write("#{@mycook.app_root}/public/.htaccess", %Q{
				RewriteEngine on
				RewriteRule ^htaccess_welcome$ welcome [PT,QSA,L]
				RewriteRule ^htaccess_cgi_environment$ welcome/cgi_environment [PT,QSA,L]
			})
			get('/htaccess_welcome').should =~ /Welcome to MyCook/
			cgi_envs = get('/htaccess_cgi_environment?foo=bar+baz')
			cgi_envs.should include("REQUEST_URI = /welcome/cgi_environment?foo=bar+baz\n")
			cgi_envs.should include("PATH_INFO = /welcome/cgi_environment\n")
		end
	end
	
	describe "configuration options" do
		before :all do
			create_apache2_controller
			@apache2 << "PassengerMaxPoolSize 3"
			
			@mycook = ClassicRailsStub.new('rails_apps/2.3/mycook')
			@mycook_url_root = "http://1.passenger.test:#{@apache2.port}"
			@apache2.set_vhost('1.passenger.test', "#{@mycook.full_app_root}/public") do |vhost|
				vhost << "AllowEncodedSlashes on"
			end
			
			@foobar = ClassicRailsStub.new('rails2.3')
			@foobar_url_root = "http://3.passenger.test:#{@apache2.port}"
			@apache2.set_vhost('3.passenger.test', "#{@foobar.full_app_root}/public") do |vhost|
				vhost << "RailsEnv development"
				vhost << "PassengerSpawnMethod conservative"
				vhost << "PassengerRestartDir #{@foobar.full_app_root}/public"
			end
			
			@mycook2 = ClassicRailsStub.new('rails_apps/2.3/mycook')
			@mycook2_url_root = "http://4.passenger.test:#{@apache2.port}"
			@apache2.set_vhost('4.passenger.test', "#{@mycook2.full_app_root}/sites/some.site/public") do |vhost|
				vhost << "PassengerAppRoot #{@mycook2.full_app_root}"
			end
			
			@apache2.start
		end
		
		after :all do
			@mycook.destroy
			@foobar.destroy
			@mycook2.destroy
			@apache2.stop if @apache2
		end
		
		before :each do
			@mycook.reset
			@foobar.reset
			@mycook2.reset
		end
		
		specify "RailsEnv is per-virtual host" do
			@server = @mycook_url_root
			get('/welcome/rails_env').should == "production"
			
			@server = @foobar_url_root
			get('/foo/rails_env').should == "development"
		end
		
		it "looks for restart.txt in the directory specified by PassengerRestartDir" do
			@server = @foobar_url_root
			controller = "#{@foobar.app_root}/app/controllers/bar_controller.rb"
			restart_file = "#{@foobar.app_root}/public/restart.txt"
			
			File.write(controller, %Q{
				class BarController < ApplicationController
					def index
						render :text => 'hello world'
					end
				end
			})
			
			now = Time.now
			File.touch(restart_file, now - 5)
			get('/bar').should == "hello world"
			
			File.write(controller, %Q{
				class BarController < ApplicationController
					def index
						render :text => 'oh hai'
					end
				end
			})
			
			File.touch(restart_file, now - 10)
			get('/bar').should == "oh hai"
		end
		
		describe "PassengerAppRoot" do
			before :each do
				@server = @mycook2_url_root
			end
			
			it "supports page caching on non-index URIs" do
				get('/welcome/cached.html').should =~ %r{This is the cached version of some.site/public/welcome/cached}
			end
			
			it "supports page caching on index URIs" do
				get('/uploads.html').should =~ %r{This is the cached version of some.site/public/uploads}
			end
			
			it "works as a rails application" do
				result = get('/welcome/parameters_test?hello=world&recipe[name]=Green+Bananas')
				result.should =~ %r{<hello>world</hello>}
				result.should =~ %r{<recipe>}
				result.should =~ %r{<name>Green Bananas</name>}
			end
		end
		
		specify "it resolves symlinks in the document root if PassengerResolveSymlinksInDocumentRoot is set" do
			orig_mycook_app_root = @mycook.app_root
			@mycook.move(File.expand_path('tmp.mycook.symlinktest'))
			FileUtils.mkdir_p(orig_mycook_app_root)
			File.symlink("#{@mycook.app_root}/public", "#{orig_mycook_app_root}/public")
			begin
				File.write("#{@mycook.app_root}/public/.htaccess", "PassengerResolveSymlinksInDocumentRoot on")
				@server = @mycook_url_root
				get('/').should =~ /Welcome to MyCook/
			ensure
				FileUtils.rm_rf(orig_mycook_app_root)
				@mycook.move(orig_mycook_app_root)
			end
		end
		
		it "supports encoded slashes in the URL if AllowEncodedSlashes is turned on" do
			@server = @mycook_url_root
			File.write("#{@mycook.app_root}/public/.htaccess", "PassengerAllowEncodedSlashes on")
			get('/welcome/show_id/foo%2fbar').should == 'foo/bar'
		end
		
		####################################
	end
	
	describe "error handling" do
		before :all do
			create_apache2_controller
			FileUtils.rm_rf('tmp.webdir')
			FileUtils.mkdir_p('tmp.webdir')
			@webdir = File.expand_path('tmp.webdir')
			@apache2.set_vhost('1.passenger.test', @webdir) do |vhost|
				vhost << "RailsBaseURI /app-with-nonexistant-rails-version/public"
				vhost << "RailsBaseURI /app-that-crashes-during-startup/public"
			end
			
			@mycook = ClassicRailsStub.new('rails_apps/2.3/mycook')
			@mycook_url_root = "http://2.passenger.test:#{@apache2.port}"
			@apache2.set_vhost('2.passenger.test', "#{@mycook.full_app_root}/public")
			
			@apache2.start
		end
		
		after :all do
			FileUtils.rm_rf('tmp.webdir')
			@mycook.destroy
			@apache2.stop if @apache2
		end
		
		before :each do
			@server = "http://1.passenger.test:#{@apache2.port}"
			@error_page_signature = /<meta name="generator" content="Phusion Passenger">/
			@mycook.reset
		end
		
		it "displays an error page if the Rails application requires a nonexistant Rails version" do
			ClassicRailsStub.use('rails2.3', "#{@webdir}/app-with-nonexistant-rails-version") do |stub|
				File.write(stub.environment_rb) do |content|
					content.sub(/^RAILS_GEM_VERSION = .*$/, "RAILS_GEM_VERSION = '1.9.1234'")
				end
				get("/app-with-nonexistant-rails-version/public").should =~ @error_page_signature
			end
		end
		
		it "displays an error page if the Rails application crashes during startup" do
			ClassicRailsStub.use('rails2.3', "#{@webdir}/app-that-crashes-during-startup") do |stub|
				File.prepend(stub.environment_rb, "raise 'app crash'")
				result = get("/app-that-crashes-during-startup/public")
				result.should =~ @error_page_signature
				result.should =~ /app crash/
			end
		end
		
		it "displays an error if a filesystem permission error was encountered while autodetecting the application type" do
			@server = @mycook_url_root
			# This test used to fail because we were improperly blocking mod_autoindex,
			# resulting in it displaying a directory index before we could display an
			# error message.
			File.chmod(0000, "#{@mycook.app_root}/config")
			# Don't let mod_rewrite kick in so that mod_autoindex has a chance to run.
			File.unlink("#{@mycook.app_root}/public/.htaccess")
			get('/').should =~ /Please fix the relevant file permissions/
		end
		
		it "doesn't display a Ruby spawn error page if PassengerFriendlyErrorPages is off" do
			ClassicRailsStub.use('rails2.3', "#{@webdir}/app-that-crashes-during-startup") do |stub|
				File.write("#{stub.app_root}/public/.htaccess", "PassengerFriendlyErrorPages off")
				File.prepend(stub.environment_rb, "raise 'app crash'")
				result = get("/app-that-crashes-during-startup/public")
				result.should_not =~ @error_page_signature
				result.should_not =~ /app crash/
			end
		end
	end
	
	describe "HelperAgent" do
		AdminTools = PhusionPassenger::AdminTools
		
		before :all do
			create_apache2_controller
			@mycook = ClassicRailsStub.new('rails_apps/2.3/mycook')
			@mycook_url_root = "http://1.passenger.test:#{@apache2.port}"
			@apache2.set_vhost('1.passenger.test', "#{@mycook.full_app_root}/public")
			@apache2.start
			@server = "http://1.passenger.test:#{@apache2.port}"
		end
		
		after :all do
			@mycook.destroy
			@apache2.stop if @apache2
		end
		
		before :each do
			@mycook.reset
		end
		
		it "is restarted if it crashes" do
			# Make sure that all Apache worker processes have connected to
			# the helper server.
			10.times do
				get('/welcome').should =~ /Welcome to MyCook/
				sleep 0.1
			end
			
			# Now kill the helper server.
			instance = AdminTools::ServerInstance.list.first
			Process.kill('SIGKILL', instance.helper_agent_pid)
			sleep 0.02 # Give the signal a small amount of time to take effect.
			
			# Each worker process should detect that the old
			# helper server has died, and should reconnect.
			10.times do
				get('/welcome').should =~ /Welcome to MyCook/
				sleep 0.1
			end
		end
		
		it "exposes the application pool for passenger-status" do
			File.touch("#{@mycook.app_root}/tmp/restart.txt", 1)  # Get rid of all previous app processes.
			get('/welcome').should =~ /Welcome to MyCook/
			instance = AdminTools::ServerInstance.list.first
			
			# Wait until the server has processed the session close event.
			sleep 0.1
			
			processes = instance.connect(:role => :passenger_status) do |client|
				instance.processes(client)
			end
			processes.should have(1).item
			processes[0].group.name.should == @mycook.full_app_root + "#default"
			processes[0].processed.should == 1
		end
	end
	
	describe "Rack application running in root URI" do
		before :all do
			create_apache2_controller
			@stub = RackStub.new('rack')
			@apache2.set_vhost('passenger.test', @stub.full_app_root + "/public")
			@apache2.start
			@server = "http://passenger.test:#{@apache2.port}"
		end
		
		after :all do
			@stub.destroy
			@apache2.stop if @apache2
		end
		
		it_should_behave_like "HelloWorld Rack application"
	end
	
	describe "Rack application running in sub-URI" do
		before :all do
			create_apache2_controller
			FileUtils.rm_rf('tmp.webdir')
			FileUtils.mkdir_p('tmp.webdir')
			@stub = RackStub.new('rack')
			@apache2.set_vhost('passenger.test', File.expand_path('tmp.webdir')) do |vhost|
				FileUtils.ln_s(@stub.full_app_root + "/public", 'tmp.webdir/rack')
				vhost << "RackBaseURI /rack"
			end
			@apache2.start
			@server = "http://passenger.test:#{@apache2.port}/rack"
		end
		
		after :all do
			@stub.destroy
			FileUtils.rm_rf('tmp.webdir')
			@apache2.stop if @apache2
		end
		
		it_should_behave_like "HelloWorld Rack application"
	end
	
	describe "Rack application running within Rails directory structure" do
		before :all do
			create_apache2_controller
			@stub = ClassicRailsStub.new('rails_apps/2.3/mycook')
			FileUtils.cp_r("stub/rack/.", @stub.app_root)
			@apache2.set_vhost('passenger.test', @stub.full_app_root + "/public")
			@apache2.start
			@server = "http://passenger.test:#{@apache2.port}"
		end

		after :all do
			@stub.destroy
			@apache2.stop if @apache2
		end

		it_should_behave_like "HelloWorld Rack application"
	end

	describe "WSGI application running in root URI" do
		before :all do
			create_apache2_controller
			@stub = Stub.new('wsgi')
			@apache2.set_vhost('passenger.test', @stub.full_app_root + "/public")
			@apache2.start
			@server = "http://passenger.test:#{@apache2.port}"
		end
		
		after :all do
			@stub.destroy
			@apache2.stop if @apache2
		end
		
		it_should_behave_like "HelloWorld WSGI application"
	end
	
	##### Helper methods #####
	
	def start_web_server_if_necessary
		if !@apache2.running?
			@apache2.start
		end
	end
end
