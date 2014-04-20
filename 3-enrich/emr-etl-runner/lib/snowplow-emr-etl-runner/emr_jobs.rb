# Copyright (c) 2012-2013 SnowPlow Analytics Ltd. All rights reserved.
#
# This program is licensed to you under the Apache License Version 2.0,
# and you may not use this file except in compliance with the Apache License Version 2.0.
# You may obtain a copy of the Apache License Version 2.0 at http://www.apache.org/licenses/LICENSE-2.0.
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the Apache License Version 2.0 is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the Apache License Version 2.0 for the specific language governing permissions and limitations there under.

# Author::    Alex Dean (mailto:support@snowplowanalytics.com)
# Copyright:: Copyright (c) 2012-2013 SnowPlow Analytics Ltd
# License::   Apache License Version 2.0

require 'set'
require 'elasticity'

# Ruby class to execute SnowPlow's Hive jobs against Amazon EMR
# using Elasticity (https://github.com/rslifka/elasticity).
module SnowPlow
  module EmrEtlRunner
    class EmrJob

      # Constants
      JAVA_PACKAGE = "com.snowplowanalytics.snowplow"

      # Need to understand the status of all our jobflow steps
      @@running_states = Set.new(%w(WAITING RUNNING PENDING SHUTTING_DOWN))
      @@failed_states  = Set.new(%w(FAILED CANCELLED))

      # Initializes our wrapper for the Amazon EMR client.
      #
      # Parameters:
      # +config+:: contains all the control data for the SnowPlow Hive job
      def initialize(config)

        puts "Initializing EMR jobflow"

        # Create a job flow with your AWS credentials
        @jobflow = Elasticity::JobFlow.new(config[:aws][:access_key_id], config[:aws][:secret_access_key])

        # Configure
        @jobflow.name = config[:etl][:job_name]
        @jobflow.hadoop_version = config[:emr][:hadoop_version]
        @jobflow.ec2_key_name = config[:emr][:ec2_key_name]
        @jobflow.placement = config[:emr][:placement]
        @jobflow.ec2_subnet_id = config[:emr][:ec2_subnet_id]
        @jobflow.log_uri = config[:s3][:buckets][:log]
        @jobflow.enable_debugging = config[:debug]
        @jobflow.visible_to_all_users = true

        hbase = config[:emr][:software][:hbase]
        unless not hbase
          install_hbase_action = Elasticity::BootstrapAction.new("s3://#{config[:s3][:region]}.elasticmapreduce/bootstrap-actions/setup-hbase")
          @jobflow.add_bootstrap_action(install_hbase_action)

          start_hbase_step = Elasticity::CustomJarStep.new('/home/hadoop/lib/hbase-#{hbase}.jar')
          start_hbase_step.name = "Start HBase #{hbase}"
          start_hbase_step.arguments = [ 'emr.hbase.backup.Main', '--start-master' ]
          @jobflow.add_step(start_hbase_step)
        end

        # Install Lingual
        lingual = config[:emr][:software][:lingual]
        unless not lingual
          install_lingual_action = Elasticity::BootstrapAction.new("s3://files.concurrentinc.com/lingual/#{lingual}lingual-client/install-lingual-client.sh")
          @jobflow.add_bootstrap_action(install_lingual_action)
        end

        # Add extra configuration
        if config[:emr][:jobflow].respond_to?(:each)
          config[:emr][:jobflow].each { |key, value|
            k = key.to_s
            # Don't include the task fields
            if not k.start_with?("task_")
              @jobflow.send("#{k}=", value)
            end
          }
        end

        # Now let's add our task group if required
        tic = config[:emr][:jobflow][:task_instance_count]
        unless tic.nil? or tic == 0
          ig = Elasticity::InstanceGroup.new
          ig.count = tic
          ig.type  = config[:emr][:jobflow][:task_instance_type]
          tib = config[:emr][:jobflow][:task_instance_bid]
          if tib.nil?
            ig.set_on_demand_instances
          else
            ig.set_spot_instances(tib)
          end
          @jobflow.set_task_instance_group(ig)
        end

        csbr = config[:s3][:buckets][:raw]

        # 1. Compaction to HDFS

        # We only consolidate files on HDFS folder for CloudFront currently
        unless config[:etl][:collector_format] == "cloudfront"
          enrich_input = csbr[:processing]
        
        else
          enrich_input = "hdfs:///local/snowplow/raw-events"

          # Create the Hadoop MR step for the file crushing
          compact_to_hdfs_step = Elasticity::S3DistCpStep.new(
            :src         => csbr[:processing],
            :dest        => hadoop_input,
            :groupBy     => ".*\\.([0-9]+-[0-9]+-[0-9]+)-[0-9]+\\..*",
            :targetSize  => "128",
            :outputCodec => "lzo",
            :s3Endpoint  => config[:s3][:endpoint]
          )
          compact_to_hdfs_step.name << ": Raw S3 -> HDFS"

          # Add to our jobflow
          @jobflow.add_step(compact_to_hdfs_step)
        end

        # 2. Enrichment

        enrich_output = "hdfs:///local/snowplow/enriched-events"
        csbe = config[:s3][:buckets][:enriched]

        enrich_step = build_scalding_step(
          config[:enrich_asset],
          "Enrich Raw Events",
          "enrich.hadoop.EtlJob",
          { :in     => enrich_input,
            :good   => enrich_output,
            :bad    => partition_by_run(csbe[:bad],    config[:run_id]),
            :errors => partition_by_run(csbe[:errors], config[:run_id], config[:etl][:continue_on_unexpected_error])
          },
          { :input_format     => config[:etl][:collector_format],
            :maxmind_file     => config[:maxmind_asset],
            :anon_ip_quartets => config[:enrichments][:anon_ip_octets]
          }
        )
        @jobflow.add_step(enrich_step)

        # We need to copy our enriched events from HDFS back to S3
        copy_to_s3_step = Elasticity::S3DistCpStep.new(
          :src        => enrich_output,
          :dest       => partition_by_run(csbe[:good], config[:run_id]),
          :srcPattern => "part-*",
          :s3Endpoint => config[:s3][:endpoint]
        )
        copy_to_s3_step.name << ": Enriched HDFS -> S3"
        @jobflow.add_step(copy_to_s3_step)

        # 3. Shredding

        unless config[:skip].include?('shred')
          
          shred_output = "hdfs:///local/snowplow/shredded-events"
          csbs = config[:s3][:buckets][:shredded]
          
          shredded_step = build_scalding_step(
            config[:shred_asset],
            "Shred Enriched Events",
            "enrich.hadoop.ShredJob",
            { :in     => enrich_output,
              :good   => shred_output,
              :bad    => partition_by_run(csbs[:bad],    config[:run_id]),
              :errors => partition_by_run(csbs[:errors], config[:run_id], config[:etl][:continue_on_unexpected_error])
            }
          )
          @jobflow.add_step(shredded_step)

          copy_to_s3_step = Elasticity::S3DistCpStep.new(
            :src        => shred_output,
            :dest       => partition_by_run(csbs[:good], config[:run_id]),
            :srcPattern => "part-*",
            :s3Endpoint => config[:s3][:endpoint]
          )
          copy_to_s3_step.name << ": Shredded HDFS -> S3"
          @jobflow.add_step(copy_to_s3_step)
        end

      end

      # Run (and wait for) the daily ETL job.
      #
      # Throws a RuntimeError if the jobflow does not succeed.
      def run()

        jobflow_id = @jobflow.run
        puts "EMR jobflow #{jobflow_id} started, waiting for jobflow to complete..."
        status = wait_for(jobflow_id)

        if !status
          raise EmrExecutionError, "EMR jobflow #{jobflow_id} failed, check Amazon EMR console and Hadoop logs for details (help: https://github.com/snowplow/snowplow/wiki/Troubleshooting-jobs-on-Elastic-MapReduce). Data files not archived."
        end

        puts "EMR jobflow #{jobflow_id} completed successfully."
      end

      # Defines a Scalding data processing job as an Elasticity
      # jobflow step.
      #
      # Parameters:
      # +step_name+:: name of step
      # +main_class+:: Java main class to run
      # +folders+:: hash of in, good, bad, errors S3/HDFS folders
      # +extra_step_args+:: additional arguments to pass to the step
      #
      # Returns a step ready for adding to the jobflow.
      def build_scalding_step(step_name, jar, main_class, folders, extra_step_args={})

        # Build our argument hash
        arguments = extra_step_args
          .merge({
            :input_folder      => folders[:in],
            :output_folder     => folders[:good],
            :bad_rows_folder   => folders[:bad],
            :exceptions_folder => folders[:errors]
          })
          .reject { |k, v| v.nil? } # Because folders[:errors] may be empty

        # Now create the Hadoop MR step for the jobflow
        scalding_step = ScaldingStep.new(jar, "#{JAVA_PACKAGE}.#{main_class}", arguments)
        scalding_step.name << ": #{step_name}"

        scalding_step
      end

      # We need to partition our output buckets by run ID
      # Note buckets already have trailing slashes
      #
      # Parameters:
      # +folder+:: the folder to append a run ID folder to
      # +run_id+:: the run ID to append
      # +retain+:: set to false if this folder should be nillified 
      #
      # Return the folder with a run ID folder appended
      def partition_by_run(folder, run_id, retain=true)
        # TODO: s/%3D/=/ when Scalding Args supports it
        "#{folder}run%3D#{run_id}/" if retain
      end

      # Wait for a jobflow.
      # Check its status every 5 minutes till it completes.
      #
      # Parameters:
      # +jobflow_id+:: the ID of the EMR job we wait for
      #
      # Returns true if the jobflow completed without error,
      # false otherwise.
      def wait_for(jobflow_id)

        # Loop until we can quit...
        while true do
          begin
            # Count up running tasks and failures
            statuses = @jobflow.status.steps.map(&:state).inject([0, 0]) do |sum, state|
              [ sum[0] + (@@running_states.include?(state) ? 1 : 0), sum[1] + (@@failed_states.include?(state) ? 1 : 0) ]
            end

            # If no step is still running, then quit
            if statuses[0] == 0
              return statuses[1] == 0 # True if no failures
            end

            # Sleep a while before we check again
            sleep(120)

          rescue SocketError => se
            puts "Got socket error #{se}, waiting 5 minutes before checking jobflow again"
            sleep(300)
          end
        end
      end
    end

  end
end
