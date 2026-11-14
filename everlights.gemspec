Gem::Specification.new do |s|
  s.name = "everlights"
  s.version = "0.2.0"
  s.summary = "Client and CLI for the EverLights Smart Lights Bridge local API"
  s.description = "Control EverLights permanent lights over the LAN: show colors, manage sequences, and schedule shows ahead on the bridge's calendar. Unofficial; stdlib only."
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
