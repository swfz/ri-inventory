#!/usr/bin/env ruby

require 'aws-sdk'
require 'json'
require 'awesome_print'
require 'csv'
# TODO: RDS Elasticache 出力


class EC2Client
  attr_reader :ec2, :region, :autoscaling

  def initialize(region)
    @region = region

    credentials = Aws::Credentials.new(ENV['ACCESS_KEY'], ENV['SECRET_KEY'])
    @ec2 = Aws::EC2::Client.new(
      region: region,
      credentials: credentials
    )
    @autoscaling = Aws::AutoScaling::Client.new(
      region: region,
      credentials: credentials
    )
  end

  def instance_type_size
    running_instances = ec2.describe_instances.reservations.map(&:instances).flatten.select { |i| i.state.name == 'running' }
    running_instances.group_by(&:instance_type).transform_values { |instances| instances.size }
  end

  def add_tag_value(row:, tag_key:)
    row[tag_key] = row[:instance].tags.find {|tag| tag.key == tag_key.to_s }.value
    row
  end

  def by_tags(tag_keys:)
    running_instances = ec2.describe_instances.reservations.map(&:instances).flatten.select { |i| i.state.name == 'running' }
    list = running_instances.map do |instance|
      row = {
        region: region,
        instance_type: instance.instance_type,
        instance: instance,
        size: 1
      }
      tag_keys.map do |tag_key|
        add_tag_value(row: row, tag_key: tag_key)
      end

      row
    end

    list.each_with_object([]) do |row, array|
      row.delete(:instance)

      keys = [:instance_type] + tag_keys

      exist_row = array.find do |r|
        keys.all? {|k| row[k] == r[k]}
      end

      if exist_row.nil?
        array << row
      else
        exist_row[:size] += 1
      end
    end
  end

  def reserved_type_size
    active_reserved = ec2.describe_reserved_instances.reserved_instances.select { |ri| ri.state == 'active' }
    active_reserved.group_by(&:instance_type).transform_values { |ri| ri.sum(&:instance_count) }
  end

  def autoscaling_type_size
    launch_configurations = autoscaling.describe_launch_configurations.launch_configurations.group_by(&:launch_configuration_name).transform_values { |lc| lc.map(&:instance_type).first }
    scaling_groups = autoscaling.describe_auto_scaling_groups.auto_scaling_groups.map do |group|
      {
        instance_type: launch_configurations[group.launch_configuration_name],
        min_size: group.min_size
      }
    end

    scaling_groups.group_by { |asg| asg[:instance_type] }.transform_values { |groups| groups.sum { |asg| asg[:min_size] } }
  end

  def by_types
    instances = instance_type_size
    reserved = reserved_type_size
    autoscales = autoscaling_type_size
    ( instances.keys + reserved.keys ).map do |type|
      {
        region: region,
        type: type,
        reserved: reserved[type].to_i,
        instances: instances[type].to_i,
        not_enough: reserved[type].to_i - instances[type].to_i,
        scale_min_size: autoscales[type].to_i
      }
    end
  end
end

class RDSClient
end

class ElasticacheClient
end

class CSVExporter
  def self.export(data:, filename:)
    CSV.open(filename, 'w') do |csv|
      csv << data.first.keys
      data.each do |line|
        csv << line.values
      end
    end
  end
end

def main
  regions = %w[ap-northeast-1 us-east-1]
  ec2_list = regions.map do |region|
    client = EC2Client.new(region)
    client.by_types
  end.flatten

  CSVExporter.export(data: ec2_list, filename: 'ec2.csv')

  ec2_by_tag_list = regions.map do |region|
    client = EC2Client.new(region)
    client.by_tags(tag_keys: %i[Project Name])
  end.flatten

  CSVExporter.export(data: ec2_by_tag_list, filename: 'ec2_by_tags.csv')
end

main()

