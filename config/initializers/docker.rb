# frozen_string_literal: true
if !Rails.env.test? && !ENV['PRECOMPILE'] && ENV['DOCKER_FEATURE']
  DockerRegistry.check_config!

  # ensure that --cache-from is supported (v13+)
  min_version = 13
  begin
    local = Timeout.timeout(1) do
      Integer(`docker -v`[/Docker version (\d+)/, 1])
    end
    server = Timeout.timeout(1) do
      Integer(`docker info`[/Server Version: (\d+)/, 1])
    end
    if local < min_version || server < min_version
      abort "Expected docker version to be >= #{min_version}, found client: #{local} server: #{server}"
    end
  rescue
    warn "Unable to verify local docker!"
    ErrorNotifier.notify($!)
  end
end
