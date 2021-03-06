require "spec_helper"

github_token = "d092043dbbca509c8e3" << "61f812ece42156ef8d5f9" # token of user: some-public-token obfuscated so github does not delete it
access_token = TravisDedup.access_token(github_token)
repo = "some-public-token/travis-cron-test"

require 'webmock/rspec'

describe TravisDedup do
  it "does not blow up when dedupping" do
    WebMock.disable!
    TravisDedup.dedup(repo, access_token).should == [] # nothing canceled
  end

  it "can do a delete" do
    WebMock.enable!
    stub_request(:post, "https://api.travis-ci.org/foo/bar").
      to_return(:status => 204, :body => "", :headers => {})
    TravisDedup.send(:request, :post, "foo/bar", {}, {}).should == nil
  end

  describe "server" do
    include Rack::Test::Methods

    def response
      last_response.ok?.should == true
      last_response.body
    end

    def with_env(k, v)
      old = ENV[k]
      ENV[k] = v
      yield
    ensure
      ENV[k] = old
    end

    let(:app) { Sinatra::Application }
    before do
      ProdLog.stub(:write)
      LAST_CALLS.clear
    end

    describe "GET /" do
      it "says hello" do
        get '/'
        response.should == "Welcome to travis-dedup version #{TravisDedup::VERSION}"
      end
    end

    describe "POST /github" do
      before do
        TravisDedup.stub(:dedup_message).and_return("STUB")
        Sinatra::Application.any_instance.stub(:sleep)
      end

      it "calls dedup" do
        TravisDedup.should_receive(:dedup_message).and_return("Message")
        post '/github', repo: 'foo/bar', token: 'xyz'
        response.should == "Message"
      end

      it "fails without repo" do
        post '/github'
        last_response.status.should == 400
        last_response.body.should == "Missing parameter repo"
      end

      it "fails without token" do
        post '/github', repo: "foo/bar"
        last_response.status.should == 400
        last_response.body.should == "Missing parameter token"
      end

      it "sleeps given delay" do
        Sinatra::Application.any_instance.should_receive(:sleep).with(3)
        post '/github', repo: 'foo/bar', token: 'xyz', delay: '3'
      end

      it "silently fails when rate limited" do
        post '/github', repo: 'foo/bar', token: 'xyz'
        response.should == "STUB"

        post '/github', repo: 'foo/bar', token: 'xyz'
        response.should == "Too many requests"
      end

      it "uses ENV token when given" do
        with_env "TRAVIS_ACCESS_TOKEN", "fooo" do
          post '/github', repo: 'foo/bar'
          response.should == "STUB"
        end
      end
    end
  end

  describe ".cli" do
    def assert_setting(setting)
      TravisDedup.send(setting).should == nil
      yield
      TravisDedup.send(setting).should == true
    ensure
      TravisDedup.send("#{setting}=", nil)
    end

    def sh(command, options={})
      result = `#{command}`
      raise result if $?.success? == !!options[:fail]
      result
    end

    def dedup(command, options={})
      sh "#{Bundler.root}/bin/travis-dedup #{command}", options
    end

    def capture_stdout
      old, $stdout = $stdout, StringIO.new
      yield
      $stdout.string
    ensure
      $stdout = old
    end

    it "shows version" do
      dedup("-v").should == "#{TravisDedup::VERSION}\n"
    end

    it "shows help" do
      dedup("-h").should include "Stop all builds on the same PR"
    end

    it "dedups" do
      dedup("#{repo} #{access_token}").should == "Found 0 builds, canceled: None\n"
    end

    it "shows help for strange arguments" do
      dedup("saasd", fail: true).should include "Stop all builds on the same PR"
    end

    it "shows canceled ids" do
      TravisDedup.should_receive(:request).exactly(2) # cancel call
      TravisDedup.should_receive(:active_builds).and_return([{"id" => 123}, {"id" => 456}, {"id" => 123}, {"id" => 456}])
      TravisDedup.should_receive(:duplicate_builds).and_return([{"id" => 123}, {"id" => 456}])
      out = capture_stdout do
        TravisDedup.cli(["a", "b"]).should == 0
      end
      out.should == "Found 4 builds, canceled: 123, 456\n"
    end

    context "with duplicate builds on branches" do
      let(:result) do
        TravisDedup.send(:duplicate_builds, [
          {"state" => "x", "id" => 1, "pull_request_number" => nil, "branch" => "foo/bar"},
          {"state" => "x", "id" => 1, "pull_request_number" => nil, "branch" => "foo/bar"}
        ])
      end

      it "does not dedup branches" do
        result.should == []
      end

      it "dedup branches when branches is on" do
        begin
          TravisDedup.branches = true
          result.should == [{"state"=>"x", "id"=>1, "pull_request_number"=>nil, "branch"=>"foo/bar"}]
        ensure
          TravisDedup.branches = nil
        end
      end
    end

    it "dedups PRs" do
      TravisDedup.send(:duplicate_builds, [
        {"state" => "x", "id" => 1, "pull_request_number" => "123", "branch" => "master"},
        {"state" => "x", "id" => 2, "pull_request_number" => "123", "branch" => "master"}
      ]).should == [{"state" => "x", "id" => 2, "pull_request_number" => "123", "branch" => "master"}]
    end

    it "sets pro" do
      TravisDedup.should_receive(:dedup_message).and_return("")
      capture_stdout do
        assert_setting :pro do
          TravisDedup.cli(["a", "b", "--pro"]).should == 0
        end
      end
    end

    it "sets branches" do
      TravisDedup.should_receive(:dedup_message).and_return("")
      capture_stdout do
        assert_setting :branches do
          TravisDedup.cli(["a", "b", "--branches"]).should == 0
        end
      end
    end
  end
end
