# frozen_string_literal: true
require 'docker'

class DockerBuilderService
  DIGEST_SHA_REGEX = /Digest:.*(sha256:[0-9a-f]+)/i
  DOCKER_REPO_REGEX = /^BUILD DIGEST: (.*@sha256:[0-9a-f]+)/i
  include ::NewRelic::Agent::MethodTracer

  attr_reader :build, :execution

  def self.build_docker_image(dir, docker_options, output)
    output.puts("### Creating tarfile for Docker build")
    tarfile = create_docker_tarfile(dir)

    output.puts("### Running Docker build")
    docker_image =
      Docker::Image.build_from_tar(tarfile, docker_options, Docker.connection, registry_credentials) do |chunk|
        output.write_docker_chunk(chunk)
      end
    output.puts('### Docker build complete')

    docker_image
  end

  def self.create_docker_tarfile(dir)
    dir += '/' unless dir.end_with?('/')
    tempfile_name = Dir::Tmpname.create('out') {}

    # For large git repos, creating a tarfile can do a whole lot of disk IO.
    # It's possible for the puma process to seize up doing all those syscalls,
    # especially if the disk is running slow. So we create the tarfile in a
    # separate process to avoid that.
    tar_proc = -> do
      File.open(tempfile_name, 'wb+') do |tempfile|
        Docker::Util.create_relative_dir_tar(dir, tempfile)
      end
    end

    if ENV['RAILS_ENV'] == 'test'
      tar_proc.call
    else
      pid = fork(&tar_proc)
      Process.waitpid(pid)
    end

    File.new(tempfile_name, 'r')
  end

  def self.registry_credentials
    return nil unless ENV['DOCKER_REGISTRY'].present?
    {
      username: ENV['DOCKER_REGISTRY_USER'],
      password: ENV['DOCKER_REGISTRY_PASS'],
      email: ENV['DOCKER_REGISTRY_EMAIL'],
      serveraddress: ENV['DOCKER_REGISTRY']
    }
  end

  def initialize(build)
    @build = build
  end

  def run!(image_name: nil, push: false, tag_as_latest: false)
    build.docker_build_job.try(:destroy) # if there's an old build job, delete it

    job = build.create_docker_job
    build.save!

    job_execution = JobExecution.new(build.git_sha, job) do |execution, tmp_dir|
      @execution = execution
      @output = execution.output
      repository.executor = execution.executor

      if build.kubernetes_job
        run_build_image_job(job, image_name, push: push, tag_as_latest: tag_as_latest)
      elsif build_image(tmp_dir)
        ret = true
        ret = push_image(image_name, tag_as_latest: tag_as_latest) if push
        build.docker_image.remove(force: true) unless ENV["DOCKER_KEEP_BUILT_IMGS"] == "1"
        ret
      end
    end

    job_execution.on_complete { send_after_notifications }

    JobExecution.start_job(job_execution)
  end

  def run_build_image_job(local_job, image_name, push: false, tag_as_latest: false)
    k8s_job = Kubernetes::BuildJobExecutor.new(output, job: local_job)
    docker_ref = docker_image_ref(image_name, build)

    success, build_log = k8s_job.execute!(build, project,
      tag: docker_ref, push: push,
      registry: DockerBuilderService.registry_credentials, tag_as_latest: tag_as_latest)

    build.docker_ref = docker_ref
    build.docker_repo_digest = nil

    if success
      build_log.each_line do |line|
        if (match = line[DOCKER_REPO_REGEX, 1])
          build.docker_repo_digest = match
        end
      end
    end
    if build.docker_repo_digest.blank?
      output.puts "### Failed to get the image digest"
    end

    build.save!
  end

  def build_image(tmp_dir)
    Samson::Hooks.fire(:before_docker_build, tmp_dir, build, output)

    File.write("#{tmp_dir}/REVISION", build.git_sha)

    build.docker_image = DockerBuilderService.build_docker_image(tmp_dir, {}, output)
  rescue Docker::Error::UnexpectedResponseError
    # If the docker library isn't able to find an image id, it returns the
    # entire output of the "docker build" command, which we've already captured
    output.puts("Docker build failed (image id not found in response)")
    nil
  rescue Docker::Error::DockerError => e
    # If a docker error is raised, consider that a "failed" job instead of an "errored" job
    output.puts("Docker build failed: #{e.message}")
    nil
  end
  add_method_tracer :build_image

  def push_image(tag, tag_as_latest: false)
    build.docker_ref = docker_image_ref(tag, build)
    build.docker_repo_digest = nil
    output.puts("### Tagging and pushing Docker image to #{project.docker_repo}:#{build.docker_ref}")

    build.docker_image.tag(repo: project.docker_repo, tag: build.docker_ref, force: true)

    build.docker_image.push(DockerBuilderService.registry_credentials) do |chunk|
      parsed_chunk = output.write_docker_chunk(chunk)
      parsed_chunk.each do |output_hash|
        if (status = output_hash['status']) && sha = status[DIGEST_SHA_REGEX, 1]
          build.docker_repo_digest = "#{project.docker_repo}@#{sha}"
        end
      end
    end

    unless build.docker_repo_digest
      raise Docker::Error::DockerError, "Unable to get repo digest"
    end

    push_latest if tag_as_latest && build.docker_ref != 'latest'

    build.save!
    build
  rescue Docker::Error::DockerError => e
    output.puts("Docker push failed: #{e.message}\n")
    nil
  end
  add_method_tracer :push_image

  def output
    @output ||= OutputBuffer.new
  end

  private

  def repository
    @repository ||= project.repository
  end

  def project
    @build.project
  end

  def docker_image_ref(image_name, build)
    image_name.presence || build.label.try(:parameterize).presence || 'latest'
  end

  def push_latest
    output.puts "### Pushing the 'latest' tag for this image"
    build.docker_image.tag(repo: project.docker_repo, tag: 'latest', force: true)
    build.docker_image.push(DockerBuilderService.registry_credentials, tag: 'latest', force: true) do |chunk|
      output.write_docker_chunk(chunk)
    end
  end

  def send_after_notifications
    Samson::Hooks.fire(:after_docker_build, build)
    SseRailsEngine.send_event('builds', type: 'finish', build: BuildSerializer.new(build, root: nil))
  end
end
