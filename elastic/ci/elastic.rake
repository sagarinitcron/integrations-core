require 'ci/common'

def elastic_version
  ENV['FLAVOR_VERSION'] || '1.3.9'
end

def elastic_rootdir
  "#{ENV['INTEGRATIONS_DIR']}/elastic_#{elastic_version}"
end

container_name = 'dd-test-elastic'
container_port1 = 9200
container_port2 = 9300

namespace :ci do
  namespace :elastic do |flavor|
    task before_install: ['ci:common:before_install'] do
      sh %(docker kill #{container_name} 2>/dev/null || true)
      sh %(docker rm #{container_name} 2>/dev/null || true)
    end

    task install: ['ci:common:install'] do
      use_venv = in_venv
      install_requirements('elastic/requirements.txt',
                           "--cache-dir #{ENV['PIP_CACHE']}",
                           "#{ENV['VOLATILE_DIR']}/ci.log", use_venv)
    end

    task docker_setup: do |t|
      docker_cmd = 'elasticsearch -Des.node.name="batman" '
      if ['0.90.13', '1.0.3', '1.1.2', '1.2.4'].any? { |v| v == elastic_version }
        docker_image = "datadog/docker-library:elasticsearch_" + elastic_version.split('.')[0..1].join('_')
        if elastic_version == '0.90.13'
          docker_cmd += " -f"
        end
      else
        docker_image = "elasticsearch:#{elastic_version}"
      end

      container_volume = ""
      container_ports =  "-p #{container_port1}:#{container_port1} -p #{container_port2}:#{container_port2}"

      sh %(docker run -d #{container_ports} #{container_volume} --name #{container_name} #{docker_image} #{docker_cmd})

      if elastic_version[0].to_i < 2
        ENV['DD_ELASTIC_LOCAL_HOSTNAME'] = `docker inspect dd-test-elastic | grep Id`[/([0-9a-f\.]{2,})/][0..11]
      else
        ENV['DD_ELASTIC_LOCAL_HOSTNAME'] = `docker inspect dd-test-elastic | grep IPAddress`[/([0-9\.]+)/]
      end
    end

    task before_script: ['ci:common:before_script'] do
      sh %(docker logs #{container_name})
      Wait.for 'http://localhost:9200', 20
      sh %(docker logs #{container_name})
      # Create an index in ES
      http = Net::HTTP.new('localhost', 9200)
      resp = http.send_request('PUT', '/datadog/')
    end

    task script: ['ci:common:script'] do
      this_provides = [
        'elastic'
      ]
      Rake::Task['ci:common:run_tests'].invoke(this_provides)
    end

    task before_cache: ['ci:common:before_cache']

    task cleanup: ['ci:common:cleanup'] do
      sh %(docker kill #{container_name} 2>/dev/null || true)
      sh %(docker rm #{container_name} 2>/dev/null || true)
    end

    task :execute do
      if ENV['FLAVOR_VERSIONS']
        flavor_versions = ENV['FLAVOR_VERSIONS'].split(',')
      elsif ENV['FLAVOR_VERSION']
        flavor_versions = [ENV['FLAVOR_VERSION']]
      else
        flavor_versions = [nil]
      end

      exception = nil
      begin
        %w(before_install install).each do |u|
          Rake::Task["#{flavor.scope.path}:#{u}"].invoke
        end
        flavor_versions.each do |flavor_version|
          puts flavor_version
          ENV['FLAVOR_VERSION'] = flavor_version
          %w(docker_setup before_script cleanup).each do |u|
            Rake::Task["#{flavor.scope.path}:#{u}"].invoke
          end
          Rake::Task["#{flavor.scope.path}:script"].invoke
          Rake::Task["#{flavor.scope.path}:before_cache"].invoke
          puts 'Cleaning up'
          Rake::Task["#{flavor.scope.path}:cleanup"].invoke
          if flavor_version != flavor_versions.last
            %w(before_install install before_script cleanup).each do |u|
              Rake::Task["#{flavor.scope.path}:#{u}"].reenable
            end
            Rake::Task["#{flavor.scope.path}:script"].reenable
            Rake::Task["#{flavor.scope.path}:before_cache"].reenable
            Rake::Task["#{flavor.scope.path}:cleanup"].reenable
          end
        end
      rescue => e
        exception = e
        puts "Failed task: #{e.class} #{e.message}".red
      end
      if ENV['SKIP_CLEANUP']
        puts 'Skipping cleanup, disposable environments are great'.yellow
      else
        puts 'Cleaning up'
        Rake::Task["#{flavor.scope.path}:cleanup"].invoke
      end
      raise exception if exception
    end
  end
end
