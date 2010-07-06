require 'yaml'
require 'zlib'

require 'rubygems/command'
require 'rubygems/remote_fetcher'
require 'open-uri'

class Gem::Commands::MirrorCommand < Gem::Command

  def initialize
    super 'mirror', 'Mirror a gem repository'
  end

  def description # :nodoc:
    <<-EOF
The mirror command uses the ~/.gemmirrorrc config file to mirror remote gem
repositories to a local path. The config file is a YAML document that looks
like this:

  ---
  - from: http://gems.example.com # source repository URI
    to: /path/to/mirror           # destination directory

Multiple sources and destinations may be specified.
    EOF
  end

  def execute
    config_file = File.join Gem.user_home, '.gemmirrorrc'

    raise "Config file #{config_file} not found" unless File.exist? config_file

    mirrors = YAML.load_file config_file

    raise "Invalid config file #{config_file}" unless mirrors.respond_to? :each

    mirrors.each do |mir|
      raise "mirror missing 'from' field" unless mir.has_key? 'from'
      raise "mirror missing 'to' field" unless mir.has_key? 'to'

      get_from = mir['from']
      save_to = File.expand_path mir['to']

      raise "Directory not found: #{save_to}" unless File.exist? save_to
      raise "Not a directory: #{save_to}" unless File.directory? save_to

      gems_dir = File.join save_to, "gems"

      if File.exist? gems_dir then
        raise "Not a directory: #{gems_dir}" unless File.directory? gems_dir
      else
        Dir.mkdir gems_dir
      end

      get_from = URI.parse get_from

      if get_from.scheme.nil? then
        get_from = get_from.to_s
      elsif get_from.scheme == 'file' then
        # check if specified URI contains a drive letter (file:/D:/Temp)
        get_from = get_from.to_s
        get_from = if get_from =~ /^file:.*[a-z]:/i then
                     get_from[6..-1]
                   else
                     get_from[5..-1]
                   end
      end

      marshal_file = "Marshal.#{Gem.marshal_version}"
      marshal_path = File.join(save_to, marshal_file)
      marshal_cmp = marshal_file + '.Z'
      marshal_uri = "#{get_from}/#{marshal_cmp}"
      marshal_dst = File.join(save_to, marshal_cmp)

      say "fetching: #{marshal_uri}"

      update_file marshal_uri, marshal_dst do
        open marshal_path, "wb" do |out|
          out.write Zlib::Inflate.inflate(File.read(marshal_dst))
        end
      end

      source_index = Marshal.load File.read(marshal_path)

      progress = ui.progress_reporter source_index.size,
                                      "Fetching #{source_index.size} gems"
      source_index.each do |fullname, gem|
        gem_file = gem.file_name
        gem_dest = File.join gems_dir, gem_file

        gem_src = "#{get_from}/gems/#{gem_file}"

        begin
          update_file(gem_src, gem_dest)
        rescue
          old_gf = gem_file
          gem_file = gem_file.downcase
          retry if old_gf != gem_file
          alert_error $!
        end

        progress.updated gem_file
      end

      progress.done
    end
  end

  def fetcher
    Gem::RemoteFetcher.fetcher
  end

  # Update src to dst if required, run the block iff action is taken.
  def update_file(src, dst)
    last_modified = File.stat(dst).mtime rescue nil
    result = fetcher.open_uri_or_path(src, last_modified)
    if result
      open(dst, 'wb') { |f| f.write result }
      yield if block_given?
    end
  end

end

