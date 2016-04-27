module Kubernetes
  class DeployExecutor
    def initialize(output, job:)
      @output = output
      @job = job
    end

    def pid
      "Kubernetes-deploy-#{object_id}"
    end

    def stop!(_signal)
      @stopped = true
    end

    def execute!(*_commands)
      build = find_build
      release = create_release(build)
      ensure_service(release)
      create_deploys(release)

      # Wait until deploys are done and show progress
      loop do
        if @stopped # TODO: write test ... when user clicks stop, this needs to stop
          @output.puts "STOPPED"
          return false
        end

        status = release.release_docs.map { |release_doc| pod_is_ready?(release_doc) }
        if status.all?
          @output.puts "SUCCESS"
          return true
        end

        sleep 2
      end
    end

    private

    # TODO only call once per cluster and filter the output
    def pod_is_ready?(release_doc)
      group = release_doc.deploy_group
      role = release_doc.kubernetes_role.name
      pod = group.kubernetes_cluster.client.get_pods(
        namespace: group.kubernetes_namespace,
        label_selector: {
          deploy_group_id: group.id,
          project_id: @job.project_id,
          release_id: release_doc.kubernetes_release_id,
          role: role
        }.map { |k, v| "#{k}=#{v}" }.join(',')
      ).first

      phase, conditions = analyze_pod_status(pod)
      @output.puts "#{group.name} #{role}: #{phase} - #{conditions}"
      phase == "Running"
    end

    # find the docker build we are deploying
    # TODO: create it and wait ... also show creation logs etc
    def find_build
      if build = Build.find_by_git_sha(@job.commit)
        @output.puts("Found build #{build.id} for sha #{@job.commit}")
      else
        raise Samson::Hooks::UserError, "Build for sha #{@job.commit} does not exist, create it before deploying"
      end
      build
    end

    # create a realese, storing all the configuration
    def create_release(build)
      # build config for every cluster and role we want to deploy to
      group_config = @job.deploy.stage.deploy_groups.map do |group|
        # raise "#{group.name} needs to be on kubernetes" unless group.
        roles = Kubernetes::Role.where(project_id: @job.project_id).map do |role|
          {id: role.id, replicas: role.replicas} # TODO make replicas configureable
        end
        {id: group.id, roles: roles}
      end

      release = Kubernetes::Release.create_release(deploy_groups: group_config, build_id: build.id, user: @job.user)
      raise Samson::Hooks::UserError, release.errors.full_messages.inspect unless release.persisted?
      @output.puts("Created release #{release.id}\nConfig: #{group_config.inspect}")
      release
    end

    def analyze_pod_status(pod)
      if pod
        conditions = pod.status.conditions || []

        phase = if pod.status.phase == "Running"
          if conditions.all? { |c| c.status == "True" }
            "Running"
          else
            "Verifying"
          end
        else
          pod.status.phase
        end

        [phase, conditions.map { |c| "#{c.type}=#{c.status}" }.join(', ')]
      else
        ["Missing", []]
      end
    end

    # Create deploys
    def create_deploys(release)
      release.release_docs.each do |release_doc|
        @output.puts "Creating deploy for role #{release_doc.kubernetes_role.name}"
        release_doc.deploy_to_kubernetes
      end
    end

    # Create the service or report it's status
    def ensure_service(release)
      release.release_docs.each do |release_doc|
        role = release_doc.kubernetes_role
        service = release_doc.service

        if service.nil?
          @output.puts "no Service defined for role #{role.name}"
        elsif service.running?
          @output.puts "Service #{service.name} already running for role #{role.name}"
        else
          @output.puts "Creating service #{service.name} for role #{role.name}"
          release_doc.client.create_service(Kubeclient::Service.new(release_doc.service_hash))
        end
      end
    end
  end
end
