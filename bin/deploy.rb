#!/usr/bin/env ruby
require "bundler/inline"

gemfile do
  source "https://rubygems.org"
  gem "sshkit"
end

require "active_support/all"
require "sshkit"
require "sshkit/dsl"
include SSHKit::DSL

SSH_SERVER = "ubuntu@3.67.113.67".freeze
APP_DOMAIN = "ipepe.store".freeze # TODO: remove or change to example.org

APP_NAME = "example".freeze
GIT_BRANCH = "main".freeze
DNS_PREFIX = "www".freeze
APP_DIR = "/home/ubuntu/#{APP_NAME}/app/#{DNS_PREFIX}".freeze
REPO_DIR = "/home/ubuntu/#{APP_NAME}/repo".freeze
GIT_ORIGIN = `git config --get remote.origin.url`.strip

SSHKit.config.output_verbosity = :debug # Optional: Increase verbosity for debugging

on SSH_SERVER do
  if test "[ ! -x /usr/bin/docker ]"
    execute "sudo apt-get update && sudo apt-get install -y curl" if test "[ ! -x /usr/bin/curl ]"
    execute :curl, "-fsSL https://get.docker.com -o /tmp/get-docker.sh"
    execute :sh, "/tmp/get-docker.sh"
    execute :sudo, :usermod, "-aG", :docker, "ubuntu"
    execute :rm, "/tmp/get-docker.sh"
  end

  if test "[ ! -f /home/ubuntu/traefik/docker-compose.yml ]"
    execute :mkdir, "-p /home/ubuntu/traefik"
  end

  within "/home/ubuntu/traefik" do
    docker_compose_content = <<~YML
      version: '2'
      services:
        reverse-proxy:
          image: ipepe/traefik
          restart: always
          network_mode: bridge
          ports:
            - "80:80"
            - "443:443"
            - "8080:8080" # The Web UI (enabled by --api)
          volumes:
            - /var/run/docker.sock:/var/run/docker.sock # So that Traefik can listen to the Docker events
          labels:
            - "traefik.enable=true"
            - "traefik.port=8080"
            - "traefik.frontend.rule=Host:traefik.#{APP_DOMAIN}"
    YML

    upload! StringIO.new(docker_compose_content), "docker-compose.yml"
    execute :docker, :compose, :up, "-d"
  end

  execute :mkdir, "-p /home/ubuntu/kitten"
  kitten_docker_compose = <<~YML
    version: '2'
    services:
      kitten:
        image: ipepe/kitten
        restart: always
        network_mode: bridge
        expose:
          - '80'
        labels:
          - 'traefik.enable=true'
          - 'traefik.port=80'
          - 'traefik.frontend.rule=Host:kitten.ipepe.store'
  YML

  upload! StringIO.new(kitten_docker_compose), "/home/ubuntu/kitten/docker-compose.yml"
  execute :docker, :compose, "--project-name", "kitten", "-f",
          "/home/ubuntu/kitten/docker-compose.yml", "up", "-d"

  if test "[ -d #{REPO_DIR} ]"
    within REPO_DIR do
      execute :git, "remote set-url origin #{GIT_ORIGIN}"
      execute :git, "remote update --prune"
    end
  else
    if test "[ ! -f /home/ubuntu/.ssh/known_hosts ]"
      execute "ssh-keyscan github.com >> /home/ubuntu/.ssh/known_hosts"
    end
    execute :git, :clone, "--mirror", GIT_ORIGIN, REPO_DIR
  end

  execute :rm, "-rf #{APP_DIR}/"
  execute :mkdir, "-p #{APP_DIR}"

  within REPO_DIR do
    execute :git, "archive #{GIT_BRANCH} | tar -x -f - -C #{APP_DIR}"
    # save the commit sha to be used in the review app
    GIT_COMMIT_SHA = capture(:git, "rev-parse #{GIT_BRANCH}").strip
  end

  within APP_DIR do
    # TODO: remove

    upload! "deploy/reviewapp/docker-compose.yml", "#{APP_DIR}/docker-compose.yml"
    upload! "deploy/reviewapp/Dockerfile", "#{APP_DIR}/Dockerfile"

    git_changed_files = `git diff --name-only HEAD~1`.split("\n")
    git_changed_files.each do |file|
      puts "Upload #{file} to #{APP_DIR}/#{file}"
      execute :mkdir, "-p #{File.dirname("#{APP_DIR}/#{file}")}"
      upload! file, "#{APP_DIR}/#{file}"
    end

    stop_review_app_script = <<~SH
      #!/bin/bash
      docker compose down
    SH

    upload! StringIO.new(stop_review_app_script), "#{APP_DIR}/stop_review_app.sh"

    start_review_app_script = <<~SH
      #!/bin/bash
      export REMOVE_AFTER=#{REMOVE_AFTER}
      export DNS_PREFIX=#{DNS_PREFIX}
      export REVIEW_APP_HOST="#{DNS_PREFIX}.#{APP_DOMAIN}"
      export RAILS_MASTER_KEY=#{RAILS_MASTER_KEY}
      export CI_BUILD_REF_NAME=#{DNS_PREFIX}
      export GIT_COMMIT_SHA=#{GIT_COMMIT_SHA}
      export GIT_TAG=review-#{DNS_PREFIX}
      docker compose up --build --remove-orphans -d
    SH

    upload! StringIO.new(start_review_app_script), "#{APP_DIR}/start_review_app.sh"

    execute :chmod, "+x #{APP_DIR}/stop_review_app.sh"
    execute :chmod, "+x #{APP_DIR}/start_review_app.sh"

    execute :sh, "#{APP_DIR}/start_review_app.sh"
  end

  within APP_DIR do
    sleep 10
    execute :docker,
            "compose --project-name vas_ra_#{DNS_PREFIX} -f docker-compose.yml logs --tail 100"
    execute :sh, "#{APP_DIR}/stop_review_app.sh"
  end

  puts "Review app is available at https://#{DNS_PREFIX}.#{APP_DOMAIN}"
end
