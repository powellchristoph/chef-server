require "veil"
require "time"
require "optparse"

add_command_under_category "rotate-credentials", "credential-rotation", "Rotate Chef Server credentials for a given service", 2 do
  ensure_configured!

  OptionParser.new do |opts|
    opts.banner = "Usage: chef-server-ctl rotate-credentials $service_name"

    opts.on("-h", "--help", "Show this message") do
      puts opts
      exit
    end
  end.parse!(ARGV)

  begin
    service = ARGV[3]

    unless service
      log("You must provide a credential service name", :error)
      exit(1)
    end

    timestamp = Time.now.iso8601
    secrets_file = "/etc/opscode/private-chef-secrets.json"
    secrets_file_backup = File.expand_path(File.join(File.dirname(secrets_file), "#{File.basename(secrets_file)}#{timestamp}.json"))
    log("Backing up #{secrets_file} to #{secrets_file_backup}...")
    FileUtils.cp(secrets_file, secrets_file_backup)

    log("Rotating #{service}'s credentials...", :notice)
    credentials = Veil::CredentialCollection::ChefSecretsFile.from_file(secrets_file)
    credentials.rotate(service)
    credentials.save

    status = run_chef("#{base_path}/embedded/cookbooks/dna.json")
    if status.success?
      log("Removing #{secrets_file_backup}...")
      FileUtils.rm(secrets_file_backup)
      log("#{service}'s credentials have been rotated!", :notice)
      log("Run 'chef-server-ctl rotate-credentials #{service}' on each Chef Server", :notice)
      exit(0)
    else
      log("Credential rotation failed", :error)
      exit(1)
    end
  rescue => e
    log(e.message, :error)
    exit(1)
  end
end

add_command_under_category "rotate-all-credentials", "credential-rotation", "Rotate all Chef Server service credentials", 2 do
  ensure_configured!

  begin
    timestamp = Time.now.iso8601
    secrets_file = "/etc/opscode/private-chef-secrets.json"
    secrets_file_backup = File.expand_path(File.join(File.dirname(secrets_file), "#{File.basename(secrets_file)}#{timestamp}.json"))
    log("Backing up #{secrets_file} to #{secrets_file_backup}...")
    FileUtils.cp(secrets_file, secrets_file_backup)

    log("Rotating all Chef Server service credentials...", :notice)
    credentials = Veil::CredentialCollection::ChefSecretsFile.from_file(secrets_file)
    credentials.rotate_credentials
    credentials.save

    status = run_chef("#{base_path}/embedded/cookbooks/dna.json")
    if status.success?
      log("Removing #{secrets_file_backup}...")
      FileUtils.rm(secrets_file_backup)
      log("All credentials have been rotated!", :notice)
      log("Run 'chef-server-ctl rotate-all-credentials' on each Chef Server", :notice)
      exit(0)
    else
      log("Credential rotation failed", :error)
      exit(1)
    end
  rescue => e
    log(e.message, :error)
    exit(1)
  end
end

add_command_under_category "rotate-shared-secrets", "credential-rotation", "Rotate the Chef Server shared secrets and all service credentials", 2 do
  ensure_configured!

  begin
    timestamp = Time.now.iso8601
    secrets_file = "/etc/opscode/private-chef-secrets.json"
    secrets_file_backup = File.expand_path(File.join(File.dirname(secrets_file), "#{File.basename(secrets_file)}#{timestamp}"))
    log("Backing up #{secrets_file} to #{secrets_file_backup}...")
    FileUtils.cp(secrets_file, secrets_file_backup)

    log("Rotating shared credential secrets and service credentials...", :notice)
    credentials = Veil::CredentialCollection::ChefSecretsFile.from_file(secrets_file)
    credentials.rotate_hasher
    credentials.save

    status = run_chef("#{base_path}/embedded/cookbooks/dna.json")
    if status.success?
      log("Removing #{secrets_file_backup}...")
      FileUtils.rm(secrets_file_backup)
      log("The shared secrets and all service credentials have been rotated!", :notice)
      log("Please copy #{secrets_file} to each Chef Server and run 'chef-server-ctl reconfigure'", :notice)
      exit(0)
    else
      log("Shared credential rotation failed", :error)
      exit(1)
    end
  rescue => e
    log(e.message, :error)
    exit(1)
  end
end

add_command_under_category "show-service-credentials", "credential-rotation", "Show the service credentials", 2 do
  ensure_configured!

  credentials = Veil::CredentialCollection::ChefSecretsFile.from_file("/etc/opscode/private-chef-secrets.json")
  pp(credentials.legacy_credentials_hash)
  exit(0)
end

def ensure_configured!
  unless running_config
    log("You must reconfigure the Chef Server before a backup can be performed", :error)
    exit(1)
  end
end

def log(message, level = :info)
  case level
  when :info
    $stdout.puts message
  when :notice
    $stdout.puts "\e[32m#{message}\e[0m"
  when :error
    $stderr.puts "\e[31m[ERROR]\e[0m #{message}"
  end
end