require 'thor'
require 'sequel'

require_relative 'archiver'

module ProconArchiver
  class Cli < Thor
    desc 'archive [options] CONVENTION_DOMAIN_REGEX',
      'Build static sites for convention sites matching the given regex'
    option :procon_database_url,
      type: :string,
      default: 'mysql2://root@localhost/procon_development'
    def archive(convention_domain_regex)
      conn = Sequel.connect(options[:procon_database_url])

      Archiver.new(conn, convention_domain_regex).archive
    end
  end
end

ProconArchiver::Cli.start(ARGV)
