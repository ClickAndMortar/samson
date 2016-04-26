module Kubernetes
  class DeployExecutor
    attr_reader :output # someone

    def initialize(output, job:)
      @output = output
      @job = job
    end

    def pid
      "Kubernetes-deploy-#{object_id}"
    end

    def stop!(_signal)
      SseRailsEngine.manager.send(:close_connection, @output)
    end

    def execute!(*_commands)
      # find the docker build we are deploying
      # TODO: create it and wait ... also show creation logs etc
      unless build = Build.find_by_git_sha(@job.commit)
        raise Samson::Hooks::UserError, "Build for sha #{@job.commit} does not exist, create it before deploying"
      end

      # build config for every cluster and role we want to deploy to
      group_config = @job.deploy.stage.deploy_groups.map do |group|
        # raise "#{group.name} needs to be on kubernetes" unless group.
        roles = Kubernetes::Role.where(project_id: @job.project_id).map do |role|
          {id: role.id, replicas: role.replicas} # TODO make replicas configureable
        end
        {id: group.id, roles: roles}
      end

      # create a realese, storing all the configuration
      release = Kubernetes::Release.create_release(deploy_groups: group_config, build_id: build.id, user: @job.user)
      raise Samson::Hooks::UserError, release.errors.full_messages.inspect unless release.persisted?

      # start the deploy and listen to kubernetes events stream
      SseRailsEngine.manager.register(
        'rack.hijack' => lambda {},
        'rack.hijack_io' => @output
      )
      KuberDeployService.new(release).deploy!
      sleep 60
    ensure
      stop! # need to disconnect or we will accumulate dead outputs and never get GCed
    end
  end
end
