Gem::Specification.new do |s|
  s.name = "everlights"
  s.version = "1.0.0"
  s.summary = "Client and CLI for the EverLights v3 Smart Lights Bridge, through the cloud or the local API"
  s.description = "Control EverLights permanent lights: show colors, manage sequences, and schedule a year of shows ahead on the bridge's calendar from one config file, with holidays, calendar feeds and gradients. Reaches firmware B5010+ bridges through the EverLights cloud, older ones on the LAN. Unofficial; stdlib only."
  s.authors = ["Ricky Chilcott"]
  s.email = "ricky@rickychilcott.com"
  s.license = "MIT"
  s.required_ruby_version = ">= 3.1"
  s.files = Dir["lib/**/*.rb", "lib/**/*.html", "exe/*", "skills/**/*", "config/everlights.example.yml", "README.md", "LICENSE"]
  s.bindir = "exe"
  s.executables = ["everlights"]
  s.homepage = "https://github.com/rickychilcott/everlights"
  s.metadata = {
    "source_code_uri" => s.homepage,
    "bug_tracker_uri" => "#{s.homepage}/issues",
    "rubygems_mfa_required" => "true",
    "github_repo" => "ssh://github.com/rickychilcott/everlights"
  }
end
