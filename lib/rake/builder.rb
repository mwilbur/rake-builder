require 'rubygems' if RUBY_VERSION < '1.9'
require 'logger'
require 'rake'
require 'rake/tasklib'
require 'rake/path'
require 'rake/local_config'
require 'rake/file_task_alias'
require 'compiler'

module Rake

  class Formatter < Logger::Formatter
    def call(severity, time, progname, msg)
      msg2str(msg) << "\n"
    end
  end

  class Builder < TaskLib

    module VERSION #:nodoc:
      MAJOR = 0
      MINOR = 0
      TINY  = 13

      STRING = [ MAJOR, MINOR, TINY ].join('.')
    end

    class BuilderError < StandardError
      attr_accessor :namespace

      def initialize( message, namespace = nil )
        super( message )
        @namespace = namespace
      end

      def to_s
        message = super
        message = "#{ @namespace }: #{ message }" if @namespace
        message
      end
    end

    # Error indicating that the project failed to build.
    class BuildFailure < BuilderError
    end

    # The file to be built
    attr_accessor :target

    # The type of file to be built
    # One of: :executable, :static_library, :shared_library
    # If not set, this is deduced from the target.
    attr_accessor :target_type

    # The types of file that can be built
    TARGET_TYPES = [ :executable, :static_library, :shared_library ]

    # processor type: 'i386', 'x86_64', 'ppc' or 'ppc64'.
    attr_accessor :architecture

    # The programming language: 'c++', 'c' or 'objective-c' (default 'c++')
    # This also sets defaults for source_file_extension
    attr_accessor :programming_language

    # Programmaing languages that Rake::Builder can handle
    @@toolchain = {
      'c' => {
        :source_file_extension => 'c',
        :compiler              => 'gcc',
        :linker                => 'gcc',
        :archiver              => 'ar'
      },
      'c++' => {
        :source_file_extension => 'cpp',
        :compiler              => 'g++',
        :linker                => 'g++',
        :archiver              => 'ar'
      },
      'objective-c' => {
        :source_file_extension => 'm',
        :compiler              => 'gcc',
        :linker                => 'gcc',
        :archiver              => 'ar'

      },
    }

    # The compiler that will be used
    attr_accessor :compiler

    # The linker that will be used
    attr_accessor :linker

    # The archiver that will be used
    attr_accessor :archiver

    # Extension of source files (default 'cpp' for C++ and 'c' for C)
    attr_accessor :source_file_extension

    # Extension of header files (default 'h')
    attr_accessor :header_file_extension

    # The path of the Rakefile
    # All paths are relative to this
    attr_reader   :rakefile_path

    # The Rakefile
    # The file is not necessarily called 'Rakefile'
    # It is the file which calls to Rake::Builder.new
    attr_reader   :rakefile

    # Directories/file globs to search for project source files
    attr_accessor :source_search_paths

    # Directories/file globs to search for header files
    # When static libraries are installed,
    # headers are installed too.
    # During installation, the destination path is:
    #   /usr/local/include + the relative path
    # This 'relative path' is calculated as follows:
    # 1. Any files named in header_search_paths are installed directly under /usr/local/include
    # 2. The contents of any directory named in header_search_paths are also installed directly under /usr/local/include
    # 3. Files found by glob have the fixed part of the glob removed and
    #  the relative path calculated:
    # E.g. files found with './include/**/*' will have './include' removed to calculate the
    #  relative path.
    # So, ./include/my_lib/foo.h' produces a relative path of 'my_lib'
    # so the file will be installed as '/usr/local/include/my_lib/foo.h'
    attr_accessor :header_search_paths

    # (Optional) namespace for tasks
    attr_accessor :task_namespace

    # Name of the default task
    attr_accessor :default_task

    # Tasks which the target file depends upon
    attr_accessor :target_prerequisites

    # Directory to be used for object files
    attr_accessor :objects_path

    # Array of extra options to pass to the compiler
    attr_accessor :compilation_options

    # Additional include directories for compilation
    attr_accessor :include_paths

    # Additional library directories for linking
    attr_accessor :library_paths

    # extra options to pass to the linker
    attr_accessor :linker_options

    # Libraries to be linked
    attr_accessor :library_dependencies

    # The directory where 'rake install' will copy the target file
    attr_accessor :install_path

    # Name of the generated file containing source - header dependencies
    attr_reader   :makedepend_file

    # Temporary files generated during compilation and linking
    attr_accessor :generated_files

    # Each instance has its own logger
    attr_accessor :logger

    def initialize( &block )
      save_rakefile_info( block )
      initialize_attributes
      block.call( self )
      configure
      define_tasks
      define_default
    end

    private

    # Source files found in source_search_paths
    def source_files
      @source_files ||= find_files( @source_search_paths, @source_file_extension ).uniq
      @source_files
    end

    # Header files found in header_search_paths
    def header_files
      @header_files ||= find_files( @header_search_paths, @header_file_extension ).uniq
      @header_files
    end

    def initialize_attributes
      @architecture          = 'i386'
      @compiler_data         = Compiler::Base.for( :gcc )
      @logger                = Logger.new( STDOUT )
      @logger.level          = Logger::UNKNOWN
      @logger.formatter      = Formatter.new
      @programming_language  = 'c++'
      @header_file_extension = 'h'
      @objects_path          = @rakefile_path.dup
      @library_paths         = []
      @library_dependencies  = []
      @target_prerequisites  = []
      @source_search_paths   = [ @rakefile_path.dup ]
      @header_search_paths   = [ @rakefile_path.dup ]
      @target                = 'a.out'
      @generated_files       = []
      @compilation_options   = []
      @include_paths         = []
    end

    def configure
      @compilation_options   += [ architecture_option ] if RUBY_PLATFORM =~ /apple/i
      @compilation_options.uniq!

      @programming_language = @programming_language.to_s.downcase
      raise BuilderError.new( "Don't know how to build '#{ @programming_language }' programs", task_namespace ) if @@toolchain[ @programming_language ].nil?
      @compiler              ||= @@toolchain[ @programming_language ][ :compiler ]
      @linker                ||= @@toolchain[ @programming_language ][ :linker ]
      @archiver              ||= @@toolchain[ @programming_language ][ :archiver ]
      @source_file_extension ||= @@toolchain[ @programming_language ][ :source_file_extension ]

      @source_search_paths   = Rake::Path.expand_all_with_root( @source_search_paths, @rakefile_path )
      @header_search_paths   = Rake::Path.expand_all_with_root( @header_search_paths, @rakefile_path )
      @library_paths         = Rake::Path.expand_all_with_root( @library_paths, @rakefile_path )

      raise BuilderError.new( "The target name cannot be nil", task_namespace )             if @target.nil?
      raise BuilderError.new( "The target name cannot be an empty string", task_namespace ) if @target == ''
      @objects_path          = Rake::Path.expand_with_root( @objects_path, @rakefile_path )
      @target                = @target
      @target_type           ||= type( @target )
      raise BuilderError.new( "Building #{ @target_type } targets is not supported", task_namespace ) if ! TARGET_TYPES.include?( @target_type )

      @install_path          ||= default_install_path( @target_type )

      @linker_options        ||= ''
      @include_paths         += []
      @include_paths         = Rake::Path.expand_all_with_root( @include_paths.uniq, @rakefile_path )
      @generated_files       = Rake::Path.expand_all_with_root( @generated_files, @rakefile_path )

      @default_task          ||= :build
      @target_prerequisites  << @rakefile

      @makedepend_file       = @objects_path + '/.' + target_basename + '.depend.mf'

      raise BuilderError.new( "No source files found", task_namespace ) if source_files.length == 0
    end

    def define_tasks
      if @task_namespace
        namespace @task_namespace do
          define
        end
      else
        define
      end
    end

    def define_default
      name = scoped_task( @default_task )
      desc "Equivalent to 'rake #{ name }'"
      if @task_namespace
        task @task_namespace => [ name ]
      else
        task :default => [ name ]
      end
    end

    def define
      task :environment do
        logger.level = Logger::DEBUG if ENV[ 'DEBUG' ]
      end

      if @target_type == :executable
        desc "Run '#{ target_basename }'"
        task :run => :build do
          command = "cd #{ @rakefile_path } && #{ @target }"
          puts shell( command, Logger::INFO )
        end
      end

      desc "Compile and build '#{ target_basename }'"
      FileTaskAlias.define_task( :build, @target )

      desc "Build '#{ target_basename }'"
      file @target => [ scoped_task( :environment ),
                        scoped_task( :compile ),
                        *@target_prerequisites ] do | t |
        shell "rm -f #{ t.name }"
        build_commands.each do | command |
          shell command
        end
        raise BuildFailure.new( "The build command failed" ) if ! File.exist?( t.name )
      end

      desc "Compile all sources"
      # Only import dependencies when we're compiling
      # otherwise makedepend gets run on e.g. 'rake -T'
      task :compile => [ scoped_task( :environment ),
                         @makedepend_file,
                         scoped_task( :load_makedepend ),
                         *object_files ]

      source_files.each do |src|
        define_compile_task( src )
      end

      directory @objects_path

      task :local_config do
        if ! File.exist?( local_config )
          @logger.add( Logger::DEBUG, "Creating file '#{ local_config }'" )
          added_includes = @compiler_data.include_paths( missing_headers )
          config = Rake::LocalConfig.new( local_config )
          config.include_paths = added_includes
          config.save
        end
      end

      file @makedepend_file => [ scoped_task( :load_local_config ),
                                 scoped_task( :missing_headers ),
                                 @objects_path,
                                 *project_files ] do
        @logger.add( Logger::DEBUG, "Analysing dependencies" )
        command = "makedepend -f- -- #{ include_path } -- #{ file_list( source_files ) } 2>/dev/null > #{ @makedepend_file }"
        shell command
      end

      task :load_local_config => scoped_task( :local_config ) do
        config = LocalConfig.new( local_config )
        config.load
        @include_paths += Rake::Path.expand_all_with_root( config.include_paths, @rakefile_path )
      end

      task :missing_headers => [ *generated_headers ] do
        missing_headers
      end

      # Reimplemented mkdepend file loading to make objects depend on
      # sources with the correct paths:
      # the standard rake mkdepend loader doesn't do what we want,
      # as it assumes files will be compiled in their own directory.
      task :load_makedepend => @makedepend_file do
        object_to_source = source_files.inject( {} ) do | memo, source |
          mapped_object = source.gsub( '.' + @source_file_extension, '.o' )
          memo[ mapped_object ] = source
          memo
        end
        File.open( @makedepend_file ).each_line do |line|
          next if line !~ /:\s/
          mapped_object_file = $`
          header_file = $'.gsub( "\n", '' )
          # TODO: Why does it work,
          # if I make the object (not the source) depend on the header?
          source_file = object_to_source[ mapped_object_file ]
          object_file = object_path( source_file )
          object_file_task = Rake.application[ object_file ]
          object_file_task.enhance( [ header_file ] )
        end
      end

      desc "List generated files (which are removed with 'rake #{ scoped_task( :clean ) }')"
      task :generated_files do
        puts generated_files.inspect
      end

      # Re-implement :clean locally for project and within namespace
      # Standard :clean is a singleton
      desc "Remove temporary files"
      task :clean do
        generated_files.each do |file|
          shell "rm -f #{ file }"
        end
      end

      @generated_files << @target
      @generated_files << @makedepend_file

      desc "Install '#{ target_basename }' in '#{ @install_path }'"
      task :install, [] => [ scoped_task( :build ) ] do
        destination = File.join( @install_path, target_basename )
        install( @target, destination )
        install_headers if @target_type == :static_library
      end

      desc "Uninstall '#{ target_basename }' from '#{ @install_path }'"
      task :uninstall, [] => [] do
        destination = File.join( @install_path, target_basename )
        if ! File.exist?( destination )
          @logger.add( Logger::INFO, "The file '#{ destination }' does not exist" )
          next
        end
        begin
          shell "rm '#{ destination }'", Logger::INFO
        rescue Errno::EACCES => e
          raise BuilderError.new( "You do not have premission to uninstall '#{ destination }'\nTry\n $ sudo rake #{ scoped_task( :uninstall ) }", task_namespace )
        end
      end

      desc "Create a '#{ makefile_name }' to build the project"
      file "#{ makefile_name }" => [ @makedepend_file, scoped_task( :load_makedepend ) ] do | t |
        objects       = object_files.collect { | f | f.sub( "#{ @objects_path }", '$(OBJECT_DIR)' ) }
        objects_list  = objects.join( ' ' )
        case @target_type
        when :executable
          target_name = 'EXECUTABLE_TARGET'
          target_ref  = "$(#{ target_name })"
          target_actions =
"	$(LINKER) $(LINK_FLAGS) -o #{ target_ref } $(OBJECTS)
"
        when :static_library
          target_name = 'LIB_TARGET'
          target_ref  = "$(#{ target_name })"
          target_actions =
"	rm -f #{ target_ref }
	ar -cr #{ target_ref } $(OBJECTS)
	ranlib #{ target_ref }
"
        when :shared_library
          target_name = 'LIB_TARGET'
          target_ref  = "$(#{ target_name })"
          target_actions =
"	$(LINKER) -shared -o #{ target_ref } $(OBJECTS) $(LINK_FLAGS)
"
        end

        variables = <<EOT
COMPILER       = #{ @compiler }
COMPILER_FLAGS = #{ compiler_flags }
LINKER         = #{ @linker }
LINK_FLAGS     = #{ link_flags }
OBJECT_DIR     = #{ @objects_path }
OBJECTS        = #{ objects_list }
#{ target_name } = #{ @target }
EOT
        rules     = <<EOT

all: #{ target_ref }

clean:
	rm -f $(OBJECTS)
	rm -f #{ target_ref }

#{ target_ref }: $(OBJECTS)
#{ target_actions }
EOT

        source_groups = group_files_by_path( source_files )
        source_groups.each.with_index do | gp, i |
          variables << "SOURCE_#{ i + 1 } = #{ gp[ 0 ] }\n"
          rules     << <<EOT

$(OBJECT_DIR)/%.o: $(SOURCE_#{ i + 1 })/%.cpp
	$(COMPILER) -c $(COMPILER_FLAGS) -o $@ $<
EOT
        end

        File.open( t.name, 'w' ) do | file |
          file.write variables
          file.write rules
        end
      end

    end

    def generated_headers
      []
    end

    def scoped_task( task )
      if @task_namespace
        "#{ task_namespace }:#{ task }"
      else
        task
      end
    end

    def define_compile_task( source )
      object = object_path( source )
      @generated_files << object
      file object => [ source ] do |t|
        @logger.add( Logger::DEBUG, "Compiling '#{ source }'" )
        command = "#{ @compiler } -c #{ compiler_flags } -o #{ object } #{ source }"
        shell command
      end
    end

    def build_commands
      case @target_type
      when :executable
        [ "#{ @linker } -o #{ @target } #{ file_list( object_files ) } #{ link_flags }" ]
      when :static_library
        [ "#{ @archiver } -cr #{ @target } #{ file_list( object_files ) }",
        ]#  "ranlib #{ @target }" ]
      when :shared_library
        [ "#{ @linker } -shared -o #{ @target } #{ file_list( object_files ) } #{ link_flags }" ]
      end
    end

    def type( target )
      case target
      when /\.a/
        :static_library
      when /\.so/
        :shared_library
      else
        :executable
      end
    end

    # Discovery

    def missing_headers
      return @missing_headers if @missing_headers
      default_includes = @compiler_data.default_include_paths( @programming_language )
      all_includes     = default_includes + @include_paths
      @missing_headers = @compiler_data.missing_headers( all_includes, source_files )
    end

    # Compiling and linking parameters

    def include_path
      @include_paths.map { |p| "-I#{ p }" }.join( " " )
    end

    def compiler_flags
      flags = include_path + ' ' + compilation_options.join( ' ' )
      flags << ' ' << architecture_option if RUBY_PLATFORM =~ /darwin/i
      flags
    end

    def architecture_option
      "-arch #{ @architecture }"
    end

    def link_flags
      flags = [ @linker_options, library_paths_list, library_dependencies_list ]
      flags << architecture_option if RUBY_PLATFORM =~ /darwin/i
      flags.join( " " )
    end

    # Paths

    def local_config
      filename = '.rake-builder'
      Rake::Path.expand_with_root( filename, @rakefile_path )
    end

    def save_rakefile_info( block )
      if RUBY_VERSION < '1.9'
        # Hack the path from the block String representation
        @rakefile = block.to_s.match( /@([^\:]+):/ )[ 1 ]
      else
        @rakefile = block.source_location[ 0 ]
      end
      @rakefile_path = File.expand_path( File.dirname( @rakefile ) )
    end

    def object_path( source_path_name )
      o_name = File.basename( source_path_name ).gsub( '.' + @source_file_extension, '.o' )
      Rake::Path.expand_with_root( o_name, @objects_path )
    end

    def default_install_path( target_type )
      case target_type
      when :executable
        '/usr/local/bin'
      else
        '/usr/local/lib'
      end
    end

    def group_files_by_path( files )
      files.group_by do | f |
        m = f.match( /(.*?)?\/?([^\/]+)$/ )
        m[ 1 ]
      end
    end

    # Files

    def target_basename
      File.basename( @target )
    end

    def makefile_name
      extension = if ! task_namespace.nil? && ! task_namespace.to_s.empty?
                    '.' + task_namespace.to_s
                  else
                    ''
                  end
      "Makefile#{ extension }"
    end

    # Lists of files

    def find_files( paths, extension )
      files = Rake::Path.find_files( paths, extension )
      Rake::Path.expand_all_with_root( files, @rakefile_path )
    end

    # TODO: make this return a FileList, not a plain Array
    def object_files
      source_files.map { |file| object_path( file ) }
    end

    def project_files
      source_files + header_files
    end

    def file_list( files, delimiter = ' ' )
      files.join( delimiter )
    end
    
    def library_paths_list
      @library_paths.map { | path | "-L#{ path }" }.join( " " )
    end
    
    def library_dependencies_list
      @library_dependencies.map { | lib | "-l#{ lib }" }.join( " " )
    end

    def install_headers
      # TODO: make install_headers_path a configuration option
      install_headers_path = '/usr/local/include'

      project_headers.each do | installable_header |
        destination_path = File.join( install_headers_path, installable_header[ :relative_path ] )
        begin
          `mkdir -p '#{ destination_path }'`
        rescue Errno::EACCES => e
          raise BuilderError.new( "Permission denied to created directory '#{ destination_path }'", task_namespace )
        end
        install( installable_header[ :source_file ], destination_path )
      end
    end

    def project_headers
      @header_search_paths.reduce( [] ) do | memo, search |
        non_glob_search = ( search.match( /^([^\*\?]*)/ ) )[ 1 ]
        case
        when ( non_glob_search !~ /#{ @rakefile_path }/ )
          # Skip paths that are not inside the project
        when File.file?( search )
          full_path = Rake::Path.expand_with_root( search, @rakefile_path )
          memo << { :source_file => search, :relative_path => '' }
        when File.directory?( search )
          FileList[ search + '/*.' + @header_file_extension ].each do | pathname |
            full_path = Rake::Path.expand_with_root( pathname, @rakefile_path )
            memo << { :source_file => pathname, :relative_path => '' }
          end
        when ( search =~ /[\*\?]/ )
          FileList[ search ].each do | pathname |
            full_path = Rake::Path.expand_with_root( pathname, @rakefile_path )
            directory = File.dirname( full_path )
            relative  = Rake::Path.subtract_prefix( non_glob_search, directory )
            memo << { :source_file => pathname, :relative_path => relative }
          end
        else
          $stderr.puts "Bad search path: '${ search }'"
        end
        memo
      end
    end

    def install( source_pathname, destination_path )
      begin
        shell "cp '#{ source_pathname }' '#{ destination_path }'", Logger::INFO
      rescue Errno::EACCES => e
        source_filename = File.basename( source_pathname ) rescue '????'
        raise BuilderError.new( "You do not have permission to install '#{ source_filename }' to '#{ destination_path }'\nTry\n $ sudo rake install", task_namespace )
      end
    end

    def shell( command, log_level = Logger::DEBUG )
      @logger.add( log_level, command )
      `#{ command }`
    end

  end

end
