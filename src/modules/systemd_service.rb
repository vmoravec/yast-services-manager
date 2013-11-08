 module Yast
  import "Service"
  import "Mode"

  class SystemdServiceClass < Module
    LIST_UNIT_FILES_COMMAND = 'systemctl list-unit-files --type service'
    LIST_UNITS_COMMAND      = 'systemctl list-units --all --type service'
    STATUS_COMMAND          = 'systemctl status'
    COMMAND_OPTIONS         = ' --no-legend --no-pager --no-ask-password '
    TERM_OPTIONS            = ' LANG=C TERM=dumb COLUMNS=1024 '
    SERVICE_SUFFIX          = '.service'

    DEFAULT_SERVICE_SETTINGS = {
      :enabled     => false,  # Whether the service has been enabled
      :modified    => false,  # Whether the service has been changed (got enabled/disabled)
      :active      => false,  # The high-level unit activation state, i.e. generalization of SUB
      :loaded      => false,  # Reflects whether the unit definition was properly loaded
      :description => nil     # English description of the service
    }

    module Status
      LOADED   = 'loaded'
      ACTIVE   = 'active'
      INACTIVE = 'inactive'
      ENABLED  = 'enabled'
      DISABLED = 'disabled'
      SUPPORTED_STATES = [ENABLED, DISABLED]
    end

    class ServiceLoader
      attr_reader :unit_files, :units, :services
      attr_reader :supported_unit_files, :supported_units

      def initialize
        @services   = {}
        @unit_files = {}
        @units      = {}
        load_unit_files
        load_units
        @supported_unit_files = unit_files.select do |_, status|
          Status::SUPPORTED_STATES.member?(status)
        end
        @supported_units = units.reject do |name, _|
          unit_files[name] && !Status::SUPPORTED_STATES.member?(unit_files[name])
        end
        supported_units.select! { |_, attributes| attributes[:status] == Status::LOADED }
      end

      def read
        extract_services_from_units
        extract_services_from_unit_files
        services
      end

      private

      def list_unit_files
        command = TERM_OPTIONS + LIST_UNIT_FILES_COMMAND + COMMAND_OPTIONS
        SCR.Execute(Path.new('.target.bash_output'), command)
      end

      def list_units
        command = TERM_OPTIONS + LIST_UNITS_COMMAND + COMMAND_OPTIONS
        SCR.Execute(Path.new('.target.bash_output'), command)
      end

      def load_unit_files
        list_unit_files['stdout'].each_line do |line|
          service, status = line.split(/[\s]+/)
          service.chomp! SERVICE_SUFFIX
          unit_files[service] = status
        end
      end

      def load_units
        list_units['stdout'].each_line do |line|
          service, status, active, _, *description = line.split(/[\s]+/)
          service.chomp! SERVICE_SUFFIX
          units[service] = {
            :status => status,
            :active => active == Status::ACTIVE,
            :description => description.join(' ')
          }
        end
      end

      def extract_services_from_unit_files
        supported_unit_files.each do |name, status|
          next if services[name]
          services[name] = DEFAULT_SERVICE_SETTINGS.clone
          services[name][:enabled] = status == Status::ENABLED
          services[name][:active] = Yast::Service.Status(name).zero?
        end
      end

      def extract_services_from_units
        supported_units.each do |name, attributes|
          services[name] = DEFAULT_SERVICE_SETTINGS.clone
          if supported_unit_files[name]
            services[name][:enabled] =  supported_unit_files[name] == Status::ENABLED
          else
            services[name][:enabled] = Yast::Service.Enabled(name)
          end
          services[name][:loaded] = attributes[:status] == Status::LOADED
          services[name][:active] = attributes[:active]
          services[name][:description] = attributes[:description]
        end
      end
    end

    attr_reader   :services, :modified
    attr_accessor :errors, :services

    alias_method :all, :services

    def initialize
      textdomain 'services-manager'
      @errors   = []
      @modified = false
      @services = read
    end

    # Sets whether service should be running after writing the configuration
    #
    # @param String service name
    # @param Boolean running
    def activate service
      exists?(service) do
        services[service][:active]  = true
        Builtins.y2milestone "Service #{service} has been marked for activation"
        services[service][:modified] = true
        self.modified = true
      end
    end

    # Sets whether service should be running after writing the configuration
    #
    # @param String service name
    # @param Boolean running
    def deactivate service
      exists?(service) do
        services[service][:active]   = false
        services[service][:modified] = true
        self.modified = true
      end
    end

    # Returns the current setting whether service should be running
    #
    # @param String service name
    # @return Boolean running
    def active? service
      exists?(service) { services[service][:active] }
    end

    # Enables a given service (in memory only, use save() later)
    #
    # @param String service name
    # @param Boolean new service status
    def enable service
      exists?(service) do
        services[service][:enabled]  = true
        services[service][:modified] = true
        self.modified = true
      end
    end

    # Disables a given service (in memory only, use save() later)
    #
    # @param String service name
    # @param Boolean new service status
    def disable service
      exists?(service) do
        services[service][:enabled]  = false
        services[service][:modified] = true
        self.modified = true
      end
    end

    # Returns whether the given service has been enabled
    #
    # @param String service
    # @return Boolean enabled
    def enabled? service
      exists?(service) do
        services[service][:enabled]
      end
    end

    # Change the global modified status
    # Reverting modified to false also requires to set the flag for all services
    def modified= required_status
      reload if required_status == false
      @modified = required_status
    end

    def modified_services
      services.select do |name, attributes|
        attributes[:modified]
      end
    end

    def reload
      self.services = ServiceLoader.new.read
    end

    # Reads all services' data
    #
    # @return [Hash] map of services
    def read
      ServiceLoader.new.read
    end

    # Resets the global status of the object
    #
    # @return [Boolean]
    def reset
      self.errors = []
      self.modified = false
      true
    end


    # Returns only enabled services, the rest is expected to be disabled
    def export
      exported_services = services.select do |service_name, properties|
        enabled?(service_name) && properties[:loaded]
      end
      Builtins.y2milestone("Exported services: #{exported_services.keys}")
      exported_services.keys
    end

    def import imported_services=[]
      if imported_services.empty?
        Builtins.y2error("No data for import provided.")
        return false
      end
      Builtins.y2milestone("Imported services: #{imported_services}")
      non_existent_services = []
      # All imported will be enabled
      imported_services.each do |service|
        if exists?(service)
          enable(service)
        else
          non_existent_services << service
          Builtins.y2error("Service #{service} doesn't exist on this system")
        end
      end
      # The rest will be disabled
      (services.keys - imported_services).each do |service|
        disable(service)
      end
      non_existent_services.empty?
    end

    # Saves the current configuration in memory
    #
    # @return [Boolean]
    def save
      Builtins.y2milestone "Saving systemd services..."

      if !modified
        Builtins.y2milestone "No service has been changed, nothing to do..."
        return true
      end

      Builtins.y2milestone "Modified services: #{modified_services}"

      if !errors.empty?
        Builtins.y2error "Not saving the changes due to errors: " + errors.join(', ')
        return false
      end

      # Set the services enabled/disabled first
      toggle_services
      if !errors.empty?
        Builtins.y2error "There were some errors during saving: " + errors.join(', ')
        return false
      end

      # Then try to adjust services run (active/inactive)
      # Might start or stop some services that would cause system instability
      switch_services
      if !errors.empty?
        Builtins.y2error "There were some errors during saving: " + errors.join(', ')
        return false
      end

      modified_services.keys.each { |service_name| reset_service(service_name) }
      self.modified = false
      true
    end

    # Activates the service in cache
    #
    # @param [String] service name
    # @return [Boolean]
    def switch service
      active?(service) ? deactivate(service) : activate(service)
    end

    # Starts or stops the service
    #
    # @param [String] service name
    # @return [Boolean]
    def switch! service_name
      if active?(service_name)
        Yast::Service.Start(service_name)
      else
        Yast::Service.Stop(service_name)
      end
    end

    def reset_service service
      services[service][:modified] = false
    end

    # Enables the service in cache
    #
    # @param [String] service name
    # @return [Boolean]
    def toggle service
      enabled?(service) ? disable(service) : enable(service)
    end

    # Enable or disable the service
    #
    # @param [String] service name
    # @return [Boolean]
    def toggle! service
      enabled?(service) ? Yast::Service.Enable(service) : Yast::Service.Disable(service)
    end

    # Returns full information about the service as returned from systemctl command
    #
    # @param String service name
    # @return String full unformatted information
    def status service
      command = "#{TERM_OPTIONS}#{STATUS_COMMAND} #{service}#{SERVICE_SUFFIX} 2>&1"
      SCR.Execute(path('.target.bash_output'), command)['stdout']
    end

    private

    # Helper method to avoid if-else branching
    # When passed a block, this will be executed only if the service exists
    # Whitout block it returns the boolean value
    #
    # @params [String] service name
    # @return [Boolean]
    def exists? service
      exists = !!services[service]
      if exists && block_given?
        yield
      else
        exists
      end
    end

    def switch_services
        Builtins.y2milestone "Switching the services"
      services_switched = []
      services.each do |service_name, service_attributes|
        next unless service_attributes[:modified]
        if switch!(service_name)
          services_switched << service_name
        else
          change  = active?(service_name) ? 'stop' : 'start'
          status  = enabled?(service_name) ? 'enabled' : 'disabled'
          message = _("Could not %{change} %{service} which is currently %{status}. ") %
            { :change => change, :service => service_name, :status => status }
          message << status(service_name)
          errors << message
          Builtins.y2error("Error: %1", message)
        end
      end
      services_switched
    end

    def toggle_services
      services_toggled = []
      services.each do |service_name, service_attributes|
        next unless service_attributes[:modified]
        if toggle! service_name
          services_toggled << service_name
        else
          change  = enabled?(service_name) ? 'enable' : 'disable'
          message = _("Could not %{change} %{service}. ") %
            { :change => change, :service => service_name }
          message << status(service_name)
          errors << message
          Builtins.y2error("Error: %1", message)
        end
      end
      services_toggled
    end

    publish({:function => :active?,   :type => "boolean ()"           })
    publish({:function => :activate,  :type => "string (boolean)"     })
    publish({:function => :all,       :type => "map <string, map> ()" })
    publish({:function => :disable,   :type => "string (boolean)"     })
    publish({:function => :enable,    :type => "string (boolean)"     })
    publish({:function => :enabled?,  :type => "boolean ()"           })
    publish({:function => :errors,    :type => "list ()"              })
    publish({:function => :export,    :type => "list <string>"        })
    publish({:function => :import,    :type => "boolean ()"           })
    publish({:function => :modified,  :type => "boolean ()"           })
    publish({:function => :modified=, :type => "boolean (boolean)"    })
    publish({:function => :read,      :type => "map <string, map> ()" })
    publish({:function => :reset,     :type => "boolean ()"           })
    publish({:function => :save,      :type => "boolean ()"           })
    publish({:function => :status,    :type => "string (string)"      })
  end

  SystemdService = SystemdServiceClass.new
end
