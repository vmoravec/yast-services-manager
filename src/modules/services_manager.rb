require 'yast'
require 'services-manager/services_manager_profile'
require 'erb'

module Yast
  import "ServicesManagerTarget"
  import "ServicesManagerService"

  class ServicesManagerClass < Module
    include Yast::Logger

    TARGET   = 'default_target'
    SERVICES = 'services'

    attr_reader :errors

    def initialize
      textdomain 'services-manager'
      @errors = []
    end

    def export
      {
        TARGET   => ServicesManagerTarget.export,
        SERVICES => ServicesManagerService.export
      }
    end

    def auto_summary
      erb_template = File.expand_path("../../data/services-manager/autoyast_summary.erb", __FILE__)
      ERB.new(File.read(erb_template)).result(binding)
    end

    def import data
      profile = ServicesManagerProfile.new(data)
      ServicesManagerTarget.import(profile)
      ServicesManagerService.import(profile)
    end

    def reset
      ServicesManagerTarget.reset
      ServicesManagerService.reset
    end

    def read
      ServicesManagerTarget.read
      ServicesManagerService.read
    end

    # Saves the current configuration
    #
    # @return Boolean if successful
    def save
      target_saved = ServicesManagerTarget.save
      services_saved = ServicesManagerService.save
      errors << ServicesManagerService.errors
      !!(target_saved && services_saved)
    end

    # Are there any unsaved changes?
    def modified
      ServicesManagerTarget.modified || ServicesManagerService.modified
    end

    alias_method :modified?, :modified

    def modify
      ServicesManagerTarget.modified = true
      ServicesManagerService.modified = true
      true
    end

    publish({:function => :export,      :type => "map <string, any> ()"          })
    publish({:function => :import,      :type => "boolean ()"                    })
    publish({:function => :modified,    :type => "boolean ()"                    })
    publish({:function => :modify,      :type => "boolean (boolean)"             })
    publish({:function => :read,        :type => "void ()"                       })
    publish({:function => :reset,       :type => "void ()"                       })
    publish({:function => :save,        :type => "map <string, string> (boolean)"})

  end
  ServicesManager = ServicesManagerClass.new
end
